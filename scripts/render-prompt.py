#!/usr/bin/env python3
"""Rebuild the final prompt a model saw from a logged request.

Reads one logged request body (the proxy_server_request column) as JSON on
stdin, finds the model's chat template via config/chat-templates.yaml, and
renders it the way the model server does, so messages the template adds
(default system prompts, documents, tool descriptions) are visible. No call
is made to the model endpoint. Run it with `make prompt ID=<request id>`.

With --serve it instead answers POST /render (same JSON body) on port 4001;
that is the `prompt` service in docker-compose.yml, which the patched log
viewer calls to show the final prompt in the Pretty tab.
"""
import fnmatch
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

import jinja2
import yaml
from jinja2.ext import loopcontrols
from jinja2.sandbox import ImmutableSandboxedEnvironment

CONFIG_DIR = os.environ.get("CHAT_TEMPLATE_CONFIG_DIR", "/cfg")
CACHE_DIR = os.environ.get("CHAT_TEMPLATE_CACHE_DIR", "/cache")
SPECIAL_TOKENS = ("bos_token", "eos_token", "pad_token", "unk_token")
PORT = 4001


class RenderError(Exception):
    """A problem worth showing to the person as is."""


def resolve(model):
    """Return the template source for a model: an HF repo id or a local .jinja path."""
    with open(os.path.join(CONFIG_DIR, "chat-templates.yaml"), encoding="utf-8") as f:
        mapping = (yaml.safe_load(f) or {}).get("templates") or {}
    for pattern, source in mapping.items():
        if fnmatch.fnmatchcase(model, pattern):
            return source
    # OpenRouter-style suffixes (":free") are not part of the repo name.
    return "/".join(model.split(":")[0].split("/")[-2:])


def hub_get(repo, path):
    req = urllib.request.Request(f"https://huggingface.co/{repo}/resolve/main/{path}")
    if os.environ.get("HF_TOKEN"):
        req.add_header("Authorization", f"Bearer {os.environ['HF_TOKEN']}")
    try:
        with urllib.request.urlopen(req, timeout=30) as f:
            return f.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise RenderError(f"Could not fetch {path} from Hugging Face repo {repo}: HTTP {e.code}")


def load(source):
    """Return (template text, special tokens, where it came from)."""
    if source.endswith(".jinja"):
        with open(os.path.join(CONFIG_DIR, source), encoding="utf-8") as f:
            return f.read(), {}, f"config/{source}"
    cached = os.path.join(CACHE_DIR, source.replace("/", "--") + ".json")
    if os.path.exists(cached):
        with open(cached, encoding="utf-8") as f:
            c = json.load(f)
        return c["chat_template"], c["special_tokens"], f"{c['source']} (cached)"
    tokenizer_config = json.loads(hub_get(source, "tokenizer_config.json") or "{}")
    template = hub_get(source, "chat_template.jinja") or tokenizer_config.get("chat_template")
    if isinstance(template, list):  # named templates; "default" is the chat one
        template = next((t["template"] for t in template if t.get("name") == "default"), None)
    if not template:
        raise RenderError(
            f"No chat template found in Hugging Face repo {source}. "
            "Map this model to the right repo or a local .jinja file in config/chat-templates.yaml."
        )
    tokens = {}
    for name in SPECIAL_TOKENS:
        value = tokenizer_config.get(name)
        if value is not None:
            tokens[name] = value["content"] if isinstance(value, dict) else value
    c = {"source": f"https://huggingface.co/{source}", "chat_template": template, "special_tokens": tokens}
    os.makedirs(CACHE_DIR, exist_ok=True)
    with open(cached, "w", encoding="utf-8") as f:
        json.dump(c, f, indent=2)
    return template, tokens, c["source"]


def render(template, tokens, request):
    # Same Jinja setup as transformers' apply_chat_template, which model servers use.
    env = ImmutableSandboxedEnvironment(trim_blocks=True, lstrip_blocks=True, extensions=[loopcontrols])

    def tojson(x, ensure_ascii=False, indent=None, separators=None, sort_keys=False):
        return json.dumps(x, ensure_ascii=ensure_ascii, indent=indent, separators=separators, sort_keys=sort_keys)

    def raise_exception(message):
        raise jinja2.exceptions.TemplateError(message)

    env.filters["tojson"] = tojson
    env.globals["raise_exception"] = raise_exception
    env.globals["strftime_now"] = lambda fmt: datetime.now().strftime(fmt)
    variables = {
        **tokens,
        "messages": request["messages"],
        "tools": request.get("tools"),
        "documents": request.get("documents"),
        "add_generation_prompt": request.get("add_generation_prompt", True),
        "continue_final_message": request.get("continue_final_message", False),
        **(request.get("chat_template_kwargs") or {}),
    }
    return env.from_string(template).render(**variables)


def build(raw):
    """Render one logged request (JSON text); returns the prompt and where its template came from."""
    request = json.loads(raw)
    if not isinstance(request, dict) or not isinstance(request.get("messages"), list):
        raise RenderError("This log is not a chat request, so there is no chat template to apply.")
    template, tokens, origin = load(resolve(str(request.get("model", ""))))
    try:
        prompt = render(template, tokens, request)
    except jinja2.exceptions.TemplateError as e:
        raise RenderError(f"The chat template from {origin} failed on this request: {e}")
    return {"prompt": prompt, "template": origin, "truncated": "litellm_truncated" in raw}


class Handler(BaseHTTPRequestHandler):
    def _send(self, status, body=None):
        self.send_response(status)
        origin = self.headers.get("Origin")
        if origin:
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Access-Control-Allow-Headers", "content-type")
            self.send_header("Access-Control-Allow-Methods", "POST")
            self.send_header("Vary", "Origin")
        payload = json.dumps(body).encode("utf-8") if body is not None else b""
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _allowed(self):
        # Only pages served from this machine (the admin UI) may use the renderer.
        origin = self.headers.get("Origin")
        return origin is None or urlparse(origin).hostname in ("localhost", "127.0.0.1")

    def do_OPTIONS(self):
        self._send(204 if self._allowed() else 403)

    def do_POST(self):
        if not self._allowed() or self.path != "/render":
            return self._send(403 if not self._allowed() else 404, {"error": "Not available."})
        try:
            raw = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode("utf-8")
            self._send(200, build(raw))
        except RenderError as e:
            self._send(200, {"error": str(e)})
        except Exception as e:
            self._send(200, {"error": f"Could not render the prompt: {e}"})

    def log_message(self, *args):
        pass


def main():
    if "--serve" in sys.argv:
        print(f"render-prompt: listening on :{PORT}", flush=True)
        ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
    raw = sys.stdin.read().strip()
    if not raw:
        raise SystemExit("No log found with that request id (logs are deleted after 7 days).")
    try:
        result = build(raw)
    except RenderError as e:
        raise SystemExit(str(e))
    print(f"# model:    {json.loads(raw)['model']}", file=sys.stderr)
    print(f"# template: {result['template']}", file=sys.stderr)
    if result["truncated"]:
        print("# note:     the logged request was truncated in the database, so this prompt is too", file=sys.stderr)
    print(result["prompt"])


if __name__ == "__main__":
    main()
