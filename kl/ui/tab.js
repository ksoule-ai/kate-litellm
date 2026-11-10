// Adds an "Agent Sessions" entry to the LiteLLM admin UI's sidebar. Clicking it
// shows the kl chat page (served by `kl serve` on this machine) over the UI's
// content area. scripts/patch-ui.py appends this file to a script every UI page
// loads; it touches only the page's DOM, nothing inside LiteLLM's own code.
(function () {
  if (window.__klAgentsTab) return;
  window.__klAgentsTab = true;
  var PORT = "__KL_PORT__", HASH = "#agent-sessions", LINK = "kl-agents-link", PANEL = "kl-agents-panel";
  var url = "http://" + location.hostname + ":" + PORT + "/";
  var ICON = '<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor"' +
    ' stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="6" cy="6" r="3"/><path d="M6 9v12"/>' +
    '<circle cx="18" cy="9" r="3"/><path d="M18 12a6 6 0 0 1-6 6H6"/></svg>';
  var open = false, panel = null, frame = null;

  function nav() { return document.querySelector('aside[data-slot="sidebar"] nav'); }
  function main() { return document.querySelector("main"); }
  function theme() { return document.documentElement.classList.contains("dark") ? "dark" : "light"; }

  function addStyle() {
    if (document.getElementById("kl-agents-style")) return;
    var s = document.createElement("style");
    s.id = "kl-agents-style";
    // While the tab is open, the page underneath should not look selected.
    s.textContent =
      "#" + PANEL + "{position:fixed;z-index:20;background:var(--background,#fff);display:none}" +
      "#" + PANEL + " iframe{width:100%;height:100%;border:0;display:block}" +
      "#" + PANEL + " .kl-down{font:14px/1.5 system-ui,sans-serif;max-width:460px;margin:10vh auto 0;padding:24px;" +
      "border:1px solid var(--border,#e2e8f0);border-radius:10px;color:var(--foreground,#0f172a)}" +
      "#" + PANEL + " .kl-down code{font-family:ui-monospace,Menlo,monospace;background:var(--muted,#f1f5f9);padding:1px 5px;border-radius:4px}" +
      "#" + PANEL + " .kl-down button{margin-top:12px;padding:7px 14px;border-radius:6px;border:1px solid var(--border,#e2e8f0);" +
      "background:transparent;color:inherit;cursor:pointer;font:inherit}" +
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
    var after = null, model = null;
    for (var i = 0; i < links.length; i++) {
      if (/\/logs\/?$/.test(links[i].getAttribute("href"))) after = links[i];
      if (!model && links[i].getAttribute("data-active") !== "true") model = links[i];
    }
    if (!model) return;
    after = after || links[links.length - 1];
    var a = model.cloneNode(true);
    a.id = LINK;
    a.setAttribute("href", HASH);
    a.removeAttribute("data-active");
    var svg = a.querySelector("svg");
    if (svg) svg.outerHTML = ICON;
    var spans = a.querySelectorAll("span");
    for (var j = 0; j < spans.length; j++) { if (j === 0) spans[j].textContent = "Agent Sessions"; else spans[j].remove(); }
    if (!spans.length) a.appendChild(document.createTextNode("Agent Sessions"));
    a.title = "Agent Sessions";
    a.addEventListener("click", function (e) { e.preventDefault(); e.stopPropagation(); toggle(!open); });
    after.parentNode.insertBefore(a, after.nextSibling);
    mark();
  }

  function mark() {
    var a = document.getElementById(LINK);
    if (!a) return;
    if (open) a.setAttribute("data-active", "true"); else a.removeAttribute("data-active");
    a.style.background = open ? "var(--sidebar-accent, rgba(0,0,0,.06))" : "";
    a.style.color = open ? "var(--sidebar-accent-foreground, inherit)" : "";
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
      frame.title = "Agent Sessions";
      frame.src = url + "?theme=" + theme();
      frame.addEventListener("load", sendTheme);
      panel.appendChild(frame);
    }, function () {
      frame = null;
      var d = document.createElement("div");
      d.className = "kl-down";
      d.innerHTML = "<strong>Session manager not running</strong><p>Start it in a terminal with <code>kl serve</code>, then try again.</p>";
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

  // The UI redraws its sidebar as you move around: put the entry back when it goes, and follow layout and theme changes.
  var queued = false;
  new MutationObserver(function () {
    if (queued) return;
    queued = true;
    requestAnimationFrame(function () {
      queued = false;
      addLink();
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
