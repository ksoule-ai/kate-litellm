// Adds a "Cairn" entry to the top of the LiteLLM admin UI's sidebar. Clicking it
// shows the kl chat page (served by `kl serve` on this machine) over the UI's
// content area. scripts/patch-ui.py appends this file to a script every UI page
// loads; it touches only the page's DOM, nothing inside LiteLLM's own code.
(function () {
  if (window.__klAgentsTab) return;
  window.__klAgentsTab = true;
  var PORT = "__KL_PORT__", HASH = "#cairn", LINK = "kl-agents-link", PANEL = "kl-agents-panel";
  var url = "http://" + location.hostname + ":" + PORT + "/";
  // A little stack of rocks. Its colours come from the stylesheet below, so they can change when the entry is selected.
  var ICON = '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" aria-hidden="true">' +
    '<path class="kl-st-a" d="M3.6 19.6c0-1.7 3.6-2.9 8.2-2.9 4.7 0 8.6 1.1 8.6 2.8 0 1.6-3.8 2.7-8.5 2.7-4.6 0-8.3-1-8.3-2.6z"/>' +
    '<path class="kl-st-b" d="M5.9 14.7c.2-1.5 2.8-2.6 6-2.5 3.3.1 5.9 1.1 5.8 2.6-.1 1.4-2.8 2.3-6.1 2.2-3.3-.1-5.9-1-5.7-2.3z"/>' +
    '<path class="kl-st-a" d="M8.2 10.1c.2-1.2 2-2 4.2-1.9 2.3.1 4 .9 3.9 2.1-.1 1.1-1.9 1.8-4.2 1.7-2.3-.1-4-.8-3.9-1.9z"/>' +
    '<path class="kl-st-top" d="M9.9 6.1c.1-.9 1.2-1.5 2.5-1.4 1.4.1 2.4.7 2.3 1.6-.1.8-1.2 1.3-2.5 1.2-1.4-.1-2.4-.6-2.3-1.4z"/></svg>';
  var open = false, panel = null, frame = null;

  function nav() { return document.querySelector('aside[data-slot="sidebar"] nav'); }
  function main() { return document.querySelector("main"); }
  function theme() { return document.documentElement.classList.contains("dark") ? "dark" : "light"; }

  function addStyle() {
    if (document.getElementById("kl-agents-style")) return;
    var s = document.createElement("style");
    s.id = "kl-agents-style";
    // While the tab is open, the page underneath should not look selected.
    var L = "aside[data-slot=sidebar] nav #" + LINK, dark = "html.dark ";
    s.textContent =
      // The panel the page is shown in, in Cairn's own colours so nothing flashes white while it loads.
      "#" + PANEL + "{position:fixed;z-index:20;background:#faf6ef;display:none}" +
      dark + "#" + PANEL + "{background:#17130f}" +
      "#" + PANEL + " iframe{width:100%;height:100%;border:0;display:block}" +
      "#" + PANEL + " .kl-down{font:14px/1.55 system-ui,sans-serif;max-width:460px;margin:10vh auto 0;padding:28px;" +
      "border:1px solid #e8dccb;border-radius:14px;background:#fffdf9;color:#2f2721}" +
      dark + "#" + PANEL + " .kl-down{border-color:#3a3027;background:#1f1a15;color:#efe6da}" +
      "#" + PANEL + " .kl-down strong{display:block;font:600 20px/1.2 'Iowan Old Style',Palatino,Georgia,serif;margin-bottom:6px}" +
      "#" + PANEL + " .kl-down code{font-family:ui-monospace,Menlo,monospace;background:rgba(138,122,106,.15);padding:1px 5px;border-radius:4px}" +
      "#" + PANEL + " .kl-down button{margin-top:12px;padding:7px 14px;border-radius:8px;border:1px solid #c2562b;" +
      "background:#c2562b;color:#fffaf4;cursor:pointer;font:inherit;font-weight:500}" +
      // The sidebar entry: a terracotta card at the top of the sidebar, unlike any of LiteLLM's grey entries.
      L + "{height:42px!important;margin:10px 0 6px;border:1px solid #ecc9ad;border-radius:10px;" +
      "background:linear-gradient(135deg,#fdf1e6 0%,#f5dcc6 100%)!important;color:#8a3a17!important;font-weight:600;" +
      "font-size:14px;letter-spacing:.01em;box-shadow:0 1px 2px rgba(122,58,23,.12);opacity:1!important}" +
      L + ":hover{background:linear-gradient(135deg,#fbe6d4 0%,#efcbae 100%)!important;border-color:#e2b38f}" +
      L + " svg{width:20px!important;height:20px!important}" +
      L + " .kl-st-a{fill:#8a7a6a}" + L + " .kl-st-b{fill:#b19f8b}" + L + " .kl-st-top{fill:#c2562b}" +
      L + ".kl-on{background:linear-gradient(135deg,#cf6435 0%,#a9461f 100%)!important;border-color:#a9461f;color:#fffaf4!important;" +
      "box-shadow:0 2px 6px rgba(169,70,31,.35)}" +
      L + ".kl-on .kl-st-a{fill:#f3dccb}" + L + ".kl-on .kl-st-b{fill:#fffaf4}" + L + ".kl-on .kl-st-top{fill:#ffd2b8}" +
      dark + L + "{border-color:#5c3a26;background:linear-gradient(135deg,#3a2519 0%,#2b1b12 100%)!important;color:#f2b48f!important;box-shadow:none}" +
      dark + L + ":hover{background:linear-gradient(135deg,#462d1e 0%,#331f15 100%)!important}" +
      dark + L + " .kl-st-a{fill:#9c8b79}" + dark + L + " .kl-st-b{fill:#c7b49f}" + dark + L + " .kl-st-top{fill:#e07a4b}" +
      dark + L + ".kl-on{background:linear-gradient(135deg,#e07a4b 0%,#c2562b 100%)!important;border-color:#e07a4b;color:#1a120c!important}" +
      dark + L + ".kl-on .kl-st-a{fill:#5a3420}" + dark + L + ".kl-on .kl-st-b{fill:#7a4a30}" + dark + L + ".kl-on .kl-st-top{fill:#fff1e6}" +
      // While Cairn is open, the page underneath should not look selected.
      "body.kl-agents-open aside[data-slot=sidebar] nav a[data-active=true]:not(#" + LINK + ")" +
      "{background:transparent!important;opacity:.7}" +
      "body.kl-agents-open aside[data-slot=sidebar] nav a[data-active=true]:not(#" + LINK + ")::before{display:none!important}" +
      // The UI's floating "Press Ctrl K" hint sits where the chat's message box is.
      "body.kl-agents-open div.fixed.bottom-4.z-overlay{display:none!important}";
    document.head.appendChild(s);
  }

  // The entry is a copy of one of the sidebar's own links, so it looks and collapses like them.
  function addLink() {
    var n = nav();
    if (!n || document.getElementById(LINK)) return;
    var links = n.querySelectorAll("a[href]");
    var model = null;
    for (var i = 0; i < links.length && !model; i++) {
      if (links[i].getAttribute("data-active") !== "true") model = links[i];
    }
    if (!model) return;
    addStyle();
    var a = model.cloneNode(true);
    a.id = LINK;
    a.setAttribute("href", HASH);
    a.removeAttribute("data-active");
    var svg = a.querySelector("svg");
    if (svg) svg.outerHTML = ICON;
    var spans = a.querySelectorAll("span");
    for (var j = 0; j < spans.length; j++) { if (j === 0) spans[j].textContent = "Cairn"; else spans[j].remove(); }
    if (!spans.length) a.appendChild(document.createTextNode("Cairn"));
    a.title = "Cairn: your agent sessions";
    a.addEventListener("click", function (e) { e.preventDefault(); e.stopPropagation(); toggle(!open); });
    n.insertBefore(a, n.firstChild);
    mark();
  }

  function mark() {
    var a = document.getElementById(LINK);
    if (!a) return;
    if (open) a.setAttribute("data-active", "true"); else a.removeAttribute("data-active");
    a.classList.toggle("kl-on", open);
  }

  function place() {
    var m = main();
    if (!panel || !m) return;
    var r = m.getBoundingClientRect();
    panel.style.left = r.left + "px"; panel.style.top = r.top + "px";
    panel.style.width = r.width + "px"; panel.style.height = r.height + "px";
  }

  function load() {
    panel.textContent = "";
    // The page comes from another port, so a failed load cannot be seen from here. Ask first.
    fetch(url, { mode: "no-cors", cache: "no-store" }).then(function () {
      frame = document.createElement("iframe");
      frame.title = "Cairn";
      frame.src = url + "?theme=" + theme();
      frame.addEventListener("load", sendTheme);
      panel.appendChild(frame);
    }, function () {
      frame = null;
      var d = document.createElement("div");
      d.className = "kl-down";
      d.innerHTML = "<strong>Cairn is not running</strong><p>Start it in a terminal with <code>kl serve</code>, then try again.</p>";
      var b = document.createElement("button");
      b.textContent = "Try again";
      b.addEventListener("click", load);
      d.appendChild(b);
      panel.appendChild(d);
    });
  }

  function sendTheme() {
    if (frame && frame.contentWindow) frame.contentWindow.postMessage({ klTheme: theme() }, "http://" + location.hostname + ":" + PORT);
  }

  function toggle(on) {
    open = on;
    addStyle();
    if (on && !panel) {
      panel = document.createElement("div");
      panel.id = PANEL;
      document.body.appendChild(panel);
    }
    if (on && !frame) load();
    if (panel) panel.style.display = on ? "block" : "none";
    document.body.classList.toggle("kl-agents-open", on);
    if (on) { place(); if (location.hash !== HASH) history.replaceState(null, "", HASH); }
    else if (location.hash === HASH) history.replaceState(null, "", location.pathname + location.search);
    mark();
  }

  // Choosing any other sidebar entry leaves the tab.
  document.addEventListener("click", function (e) {
    if (!open || !e.target.closest) return;
    var item = e.target.closest('aside[data-slot="sidebar"] a, aside[data-slot="sidebar"] button');
    if (item && item.id !== LINK && item.getAttribute("href")) toggle(false);
  }, true);
  document.addEventListener("keydown", function (e) { if (open && e.key === "Escape") toggle(false); });
  window.addEventListener("resize", place);
  // The sidebar animates its width when collapsed or expanded: follow the content area as it changes size.
  var watched = null, sizes = window.ResizeObserver ? new ResizeObserver(function () { if (open) place(); }) : null;
  function watchMain() {
    var m = main();
    if (!sizes || !m || m === watched) return;
    if (watched) sizes.unobserve(watched);
    sizes.observe(m);
    watched = m;
  }

  // The UI redraws its sidebar as you move around: put the entry back when it goes, and follow layout and theme changes.
  var queued = false;
  new MutationObserver(function () {
    if (queued) return;
    queued = true;
    requestAnimationFrame(function () {
      queued = false;
      addLink();
      watchMain();
      if (open) { place(); sendTheme(); }
    });
  }).observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ["class", "data-collapsed"] });

  function start() {
    addLink();
    if (location.hash === HASH) {
      var tries = 0, wait = setInterval(function () {  // on a reload, open once the sidebar exists
        if (nav() && main()) { clearInterval(wait); toggle(true); } else if (++tries > 100) clearInterval(wait);
      }, 100);
    }
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start); else start();
})();
