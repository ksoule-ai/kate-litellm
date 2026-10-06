#!/usr/bin/env python3
"""Patch LiteLLM's prebuilt admin UI so the log viewer's Pretty tab shows more.

Runs inside the litellm container before the proxy starts (see the entrypoint in
docker-compose.yml). The UI ships as minified JS, so this rewrites it in place:

  - every system/developer message is shown, expanded (stock UI shows only the
    first one and collapses it at 200+ characters)
  - the request's top-level `documents` list (RAG / Granite intrinsics) is shown
    as DOCUMENT sections above the messages (stock UI hides it outside JSON)
  - a "Final prompt" section shows what the model saw after its chat template,
    rendered by the `prompt` service (scripts/render-prompt.py)

It never blocks startup: if a new image changes the bundle so the patterns no
longer match, the file is left untouched and a warning is printed. The stock
file is kept next to it as <name>.orig, so a changed patch can be re-applied.
"""
import glob
import os
import re
import sys

import litellm

CHUNKS = os.path.join(
    os.path.dirname(litellm.__file__), "proxy", "_experimental", "out", "_next", "static", "chunks"
)
MARKER = "/*kate-ui-patch*/"
PROMPT_PORT = os.environ.get("PROMPT_PORT", "4001")
ID = r"[\w$]+"

# `documents` entries become pseudo system messages carrying their own label.
DOCS = (
    '(d=>Array.isArray(d)?d.map((x,i)=>{let o=x&&"object"==typeof x,t=o&&(x.title||x.doc_id||x.id);'
    'return{role:"system",label:"DOCUMENT "+(i+1)+(t?" · "+t:""),'
    'content:o?"string"==typeof x.text?x.text:"string"==typeof x.content?x.content:JSON.stringify(x,null,2):String(x)}}):[])'
)

# Collapsed section that asks the prompt service to render the logged request.
# __R__ and __J__ are the bundle's names for React and its JSX runtime.
FINAL_PROMPT = (
    'function __katePrompt({request:q}){let[v,V]=(0,__R__.useState)(null),[o,O]=(0,__R__.useState)(!1);'
    'if(!q||!Array.isArray(q.messages))return null;'
    'let u="http://"+location.hostname+":__PORT__/render",'
    'L=()=>{V({loading:!0});let b={};'
    'for(let k of["model","messages","tools","documents","chat_template_kwargs","add_generation_prompt",'
    '"continue_final_message"])k in q&&(b[k]=q[k]);'
    'fetch(u,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(b)})'
    '.then(r=>r.json()).then(V)'
    '.catch(()=>V({error:"Could not reach the prompt renderer at "+u+". Start it with `make up`."}))},'
    'm={fontSize:11,fontWeight:400,color:"var(--color-muted-foreground)"};'
    'return(0,__J__.jsxs)("div",{style:{border:"1px solid var(--color-border)",borderRadius:6,marginBottom:8,'
    'overflow:"hidden"},children:[(0,__J__.jsxs)("div",{onClick:()=>{o||v||L(),O(!o)},style:{display:"flex",'
    'alignItems:"center",gap:8,padding:"10px 16px",background:"var(--color-muted)",cursor:"pointer",fontSize:14,'
    'fontWeight:500},children:[(0,__J__.jsx)("span",{style:m,children:o?"▾":"▸"}),"Final prompt",'
    '(0,__J__.jsx)("span",{style:m,children:"what the model saw after its chat template"})]}),'
    'o&&(0,__J__.jsxs)("div",{style:{padding:"12px 16px"},children:['
    'v&&v.loading&&(0,__J__.jsx)("div",{style:m,children:"Rendering…"}),'
    'v&&v.error&&(0,__J__.jsx)("div",{style:{fontSize:13,color:"var(--color-destructive)"},children:v.error}),'
    'v&&null!=v.prompt&&(0,__J__.jsxs)("div",{style:{...m,marginBottom:8},children:["Template: ",v.template,'
    'v.truncated?" · the logged request was cut short in the database, so this prompt is too":""]}),'
    'v&&null!=v.prompt&&(0,__J__.jsx)("pre",{style:{margin:0,fontSize:12,lineHeight:1.6,whiteSpace:"pre-wrap",'
    'wordBreak:"break-word",color:"var(--color-foreground)"},children:v.prompt})]})]})}'
)

# (pattern, replacement); each must match exactly once.
EDITS = [
    # Request parser: carry `documents` alongside chat messages.
    (
        rf'if\(Array\.isArray\(({ID})\.messages\)\)return\{{kind:"chat",messages:\1\.messages\}}',
        lambda m: f'if(Array.isArray({m[1]}.messages))return{{kind:"chat",messages:{m[1]}.messages,'
        f"extras:{DOCS}({m[1]}.documents)}}",
    ),
    # Message list: documents first, then the real messages.
    (
        rf'case"chat":return ({ID})\.messages\.map\(({ID})\)',
        lambda m: f'case"chat":return[...{m[1]}.extras||[],...{m[1]}.messages.map({m[2]})]',
    ),
    # Input card: collect every system message instead of the first.
    (
        rf'({ID})=({ID})\.find\(({ID})=>"system"===\3\.role\)',
        lambda m: f'{m[1]}={m[2]}.filter({m[3]}=>"system"==={m[3]}.role)',
    ),
    # Input card: render each one, expanded.
    (
        rf'({ID})&&(\(0,{ID}\.jsx\))\(({ID}),\{{label:"SYSTEM",content:\1\.content,'
        rf"defaultExpanded:!!\(\1\.content&&\1\.content\.length<200\)\}}\)",
        lambda m: f'{m[1]}.map((m,k)=>{m[2]}({m[3]},{{label:m.label||"SYSTEM",content:m.content,'
        f"defaultExpanded:!0}},k))",
    ),
    # Define the final-prompt section next to the SYSTEM section component.
    (
        rf"function ({ID})\(\{{label:({ID}),content:({ID}),defaultExpanded:({ID})=!1\}}\)\{{let\[({ID}),({ID})\]="
        rf"\(0,({ID})\.useState\)",
        lambda m: FINAL_PROMPT.replace("__R__", m[7]).replace("__PORT__", PROMPT_PORT) + m[0],
    ),
    # Pretty tab: put it between the Input and Output cards.
    (
        rf"\(0,({ID})\.jsx\)\(({ID}),\{{messages:({ID}),promptTokens:({ID})\?\.prompt_tokens,"
        rf"inputCost:\4\?\.input_cost\}}\),",
        lambda m: m[0] + f"(0,{m[1]}.jsx)(__katePrompt,{{request:__REQ__}},__REQ__&&__REQ__.litellm_call_id),",
    ),
]
# The Pretty tab component's name for the logged request.
REQUEST_VAR = rf"\(\{{request:({ID}),response:{ID},metrics:{ID}\}}\)"


def patch(src):
    request_var = re.findall(REQUEST_VAR, src)
    jsx = re.findall(EDITS[-1][0], src)
    if len(request_var) != 1 or len(jsx) != 1:
        return None
    for pattern, repl in EDITS:
        src, n = re.subn(pattern, repl, src)
        if n != 1:
            return None
    return MARKER + src.replace("__REQ__", request_var[0]).replace("__J__", jsx[0][0])


def main():
    chunks_dir = sys.argv[1] if len(sys.argv) > 1 else CHUNKS
    targets = []
    for path in glob.glob(os.path.join(chunks_dir, "*.js")):
        with open(path, encoding="utf-8") as f:
            src = f.read()
        if 'label:"SYSTEM"' in src or MARKER in src:
            targets.append((path, src))
    if not targets:
        print("patch-ui: WARNING log viewer chunk not found; UI left unpatched")
    for path, src in targets:
        name = os.path.basename(path)
        # Always patch from the stock file, so a changed patch replaces the old one.
        if os.path.exists(path + ".orig"):
            with open(path + ".orig", encoding="utf-8") as f:
                src = f.read()
        elif src.startswith(MARKER):
            print(f"patch-ui: WARNING {name} is patched but its original is missing; left as is")
            continue
        else:
            with open(path + ".orig", "w", encoding="utf-8") as f:
                f.write(src)
        out = patch(src)
        if out is None:
            print(f"patch-ui: WARNING {name} does not match this LiteLLM version; UI left unpatched")
            continue
        with open(path, "w", encoding="utf-8") as f:
            f.write(out)
        print(f"patch-ui: patched {name}")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # never block the gateway from starting
        print(f"patch-ui: WARNING failed: {e}")
