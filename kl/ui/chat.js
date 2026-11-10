// Chat page for the kl manager agent, served by `kl serve` and shown inside the
// gateway's admin UI. Everything from the model or the tools is put on the page
// as text, never as HTML.
(() => {
  const $ = (id) => document.getElementById(id);
  const views = ["signin", "chat", "down"];
  const show = (name) => views.forEach((v) => { $(v).hidden = v !== name; });
  const store = (kind, key, value) => {  // storage can be unavailable; the page still works for this visit
    try {
      if (value === undefined) return window[kind].getItem(key);
      if (value === null) window[kind].removeItem(key); else window[kind].setItem(key, value);
    } catch (e) { /* ignore */ }
    return value;
  };

  let token = store("localStorage", "kl.token") || "";
  let conversation = store("sessionStorage", "kl.conversation") || "";
  let busy = false;

  // The sign-in link carries the token after "#", which browsers never send to a server.
  const fromLink = /^#token=(.+)$/.exec(location.hash);
  if (fromLink) {
    token = store("localStorage", "kl.token", decodeURIComponent(fromLink[1]));
    history.replaceState(null, "", location.pathname);
  }

  const api = (path, body) => fetch(path, {
    method: body ? "POST" : "GET",
    headers: Object.assign({ Authorization: "Bearer " + token }, body ? { "Content-Type": "application/json" } : {}),
    body: body ? JSON.stringify(body) : undefined,
  });

  async function connect() {
    let res;
    try {
      res = await api("/api/health");
    } catch (e) {
      return show("down");
    }
    if (res.status === 401) return show("signin");
    if (!res.ok) return show("down");
    const info = await res.json();
    $("model").textContent = info.model_detail || info.model || "";
    $("new").hidden = false;
    show("chat");
    $("input").focus();
  }

  const el = (tag, cls, text) => {
    const node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text !== undefined) node.textContent = text;
    return node;
  };
  // Models write **bold** and `code`. Show those two, built as elements, and everything else as plain text.
  const rich = (cls, text) => {
    const node = el("div", cls);
    text.split(/(\*\*[^*\n]+\*\*|`[^`\n]+`)/).forEach((part) => {
      if (/^\*\*.+\*\*$/.test(part)) node.appendChild(el("strong", "", part.slice(2, -2)));
      else if (/^`.+`$/.test(part)) node.appendChild(el("code", "", part.slice(1, -1)));
      else if (part) node.appendChild(document.createTextNode(part));
    });
    return node;
  };
  const log = $("log");
  const scroll = () => { log.scrollTop = log.scrollHeight; };

  function setBusy(on) {
    busy = on;
    $("send").disabled = on;
    document.querySelectorAll(".confirm button").forEach((b) => { b.disabled = on; });
  }

  // Send one request and put its events on the page as they arrive, one JSON object per line.
  async function run(path, body, turn) {
    setBusy(true);
    const started = Date.now();
    const status = turn.appendChild(el("div", "status", "Working…"));
    const tick = setInterval(() => { status.textContent = `Working… ${Math.round((Date.now() - started) / 1000)}s`; }, 1000);
    let step = null;
    const handle = (e) => {
      if (e.type === "conversation") {
        conversation = store("sessionStorage", "kl.conversation", e.id);
      } else if (e.type === "tool") {
        const args = Object.entries(e.args || {}).map(([k, v]) => `${k}=${JSON.stringify(v)}`).join(", ");
        step = el("details", "step");
        step.appendChild(el("summary", "", `${e.name}(${args})`));
        step.appendChild(el("pre", "", "…"));
        turn.insertBefore(step, status);
      } else if (e.type === "tool_result") {
        if (!step) { step = el("details", "step"); step.appendChild(el("summary", "", e.name)); step.appendChild(el("pre")); turn.insertBefore(step, status); }
        step.querySelector("pre").textContent = e.text;
        step = null;
      } else if (e.type === "text") {
        turn.insertBefore(rich("answer", e.text), status);
      } else if (e.type === "error") {
        turn.insertBefore(el("div", "failed", e.text), status);
      } else if (e.type === "confirm") {
        const card = el("div", "confirm");
        card.appendChild(el("p", "", e.summary));
        const buttons = card.appendChild(el("div", "buttons"));
        const answer = (approve) => {
          card.replaceChildren(el("p", "", e.summary), el("p", "muted", approve ? "You approved this." : "You declined this."));
          run("/api/confirm", { conversation, approve }, turn);
        };
        const yes = buttons.appendChild(el("button", "primary", "Start session"));
        const no = buttons.appendChild(el("button", "", "Decline"));
        yes.type = no.type = "button";
        yes.addEventListener("click", () => answer(true));
        no.addEventListener("click", () => answer(false));
        turn.insertBefore(card, status);
      }
      scroll();
    };
    try {
      const res = await api(path, body);
      if (res.status === 401) { show("signin"); return; }
      if (!res.ok || !res.body) throw new Error(`the session manager answered ${res.status}`);
      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";
      for (;;) {
        const { done, value } = await reader.read();
        buffer += decoder.decode(value || new Uint8Array(), { stream: !done });
        const lines = buffer.split("\n");
        buffer = lines.pop();
        lines.filter((l) => l.trim()).forEach((l) => handle(JSON.parse(l)));
        if (done) break;
      }
    } catch (e) {
      turn.insertBefore(el("div", "failed", `Lost contact with the session manager (${e.message}). Is \`kl serve\` still running?`), status);
    } finally {
      clearInterval(tick);
      status.remove();
      setBusy(false);
      scroll();
      $("input").focus();
    }
  }

  function ask(text) {
    text = text.trim();
    if (!text || busy) return;
    $("empty").hidden = true;
    // A request waiting for a yes or no is declined by the server when a new message arrives.
    document.querySelectorAll(".confirm .buttons").forEach((b) => b.replaceWith(el("p", "muted", "Not answered; treated as declined.")));
    const turn = log.appendChild(el("div", "turn"));
    turn.appendChild(el("div", "you", text));
    $("input").value = "";
    $("input").style.height = "";
    scroll();
    run("/api/chat", { conversation, message: text }, turn);
  }

  $("ask").addEventListener("submit", (e) => { e.preventDefault(); ask($("input").value); });
  $("input").addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); ask($("input").value); }
  });
  $("input").addEventListener("input", () => {
    $("input").style.height = "";
    $("input").style.height = Math.min($("input").scrollHeight + 2, 160) + "px";
  });
  $("suggestions").addEventListener("click", (e) => { if (e.target.tagName === "BUTTON") ask(e.target.textContent); });
  $("new").addEventListener("click", () => {
    if (busy) return;
    conversation = store("sessionStorage", "kl.conversation", null) || "";
    log.querySelectorAll(".turn").forEach((t) => t.remove());
    $("empty").hidden = false;
    $("input").focus();
  });
  $("retry").addEventListener("click", connect);
  $("signin-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    token = $("token").value.trim();
    const res = await api("/api/health").catch(() => null);
    if (res && res.ok) { store("localStorage", "kl.token", token); $("token").value = ""; $("signin-error").hidden = true; connect(); }
    else if (res) $("signin-error").hidden = false;
    else show("down");
  });
  // Signing in through the link in another tab connects this one too.
  window.addEventListener("storage", (e) => { if (e.key === "kl.token" && e.newValue) { token = e.newValue; connect(); } });
  // The admin UI tells this page which theme it is using.
  window.addEventListener("message", (e) => {
    if (e.data && (e.data.klTheme === "dark" || e.data.klTheme === "light")) document.documentElement.dataset.theme = e.data.klTheme;
  });
  if (/[?&]theme=dark\b/.test(location.search)) document.documentElement.dataset.theme = "dark";

  connect();
})();
