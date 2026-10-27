/* Shared behaviour: theme, copy buttons, the API filter, and the display-width
   correction for any glyph that is not one character cell wide. */

(function () {
  const root = document.documentElement;
  const saved = localStorage.getItem("moonpool-theme");
  if (saved === "light" || saved === "dark") root.dataset.theme = saved;

  const prefersDark = window.matchMedia("(prefers-color-scheme: dark)");
  const isDark = () => {
    const t = root.dataset.theme;
    return t === "dark" || (!t && prefersDark.matches);
  };

  function paintThemeButton() {
    const b = document.querySelector(".themebtn");
    if (!b) return;
    b.textContent = isDark() ? "☾" : "☀";
    const label = isDark() ? "Switch to the daylight pool" : "Switch to the night pool";
    b.setAttribute("aria-label", label);
    b.title = label;
  }

  document.addEventListener("click", (e) => {
    const t = e.target.closest(".themebtn");
    if (t) {
      root.dataset.theme = isDark() ? "light" : "dark";
      localStorage.setItem("moonpool-theme", root.dataset.theme);
      paintThemeButton();
      document.dispatchEvent(new CustomEvent("moonpool:theme"));
      return;
    }
    const c = e.target.closest(".copy, [data-copy]");
    if (!c) return;
    const text = c.dataset.copy || (c.closest(".code") ? c.closest(".code").querySelector("pre").innerText : "");
    const was = c.textContent;
    navigator.clipboard.writeText(text).then(
      () => {
        c.classList.add("done");
        c.textContent = "copied";
        setTimeout(() => {
          c.classList.remove("done");
          c.textContent = was;
        }, 1300);
      },
      () => {
        c.textContent = "ctrl+c";
      }
    );
  });

  const WIDE =
    /[\u1100-\u115F\u2E80-\u303E\u3041-\u33FF\u4E00-\u9FFF\uAC00-\uD7A3\uFF00-\uFF60\u{1F300}-\u{1FAFF}]/u;

  function alignGlyphs(scope) {
    scope.querySelectorAll(".term").forEach((block) => {
      if (block.dataset.aligned) return;
      block.dataset.aligned = "1";
      const walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT);
      const nodes = [];
      while (walker.nextNode()) nodes.push(walker.currentNode);
      nodes.forEach((node) => {
        const text = node.nodeValue;
        if (!/[^\x00-\x7F]/.test(text)) return;
        const frag = document.createDocumentFragment();
        for (const ch of text) {
          if (ch === "\n" || /^[\x00-\x7F]$/.test(ch)) {
            frag.appendChild(document.createTextNode(ch));
          } else {
            const span = document.createElement("span");
            span.className = "glyph" + (WIDE.test(ch) ? " w2" : "");
            span.textContent = ch;
            frag.appendChild(span);
          }
        }
        node.parentNode.replaceChild(frag, node);
      });
    });
  }

  function wireFilter() {
    const input = document.getElementById("api-filter");
    if (!input || input.dataset.wired) return;
    input.dataset.wired = "1";
    const entries = [...document.querySelectorAll(".entry")];
    const bands = [...document.querySelectorAll(".band")];
    const count = document.getElementById("api-count");
    const total = entries.length;
    const apply = () => {
      const q = input.value.trim().toLowerCase();
      let shown = 0;
      entries.forEach((e) => {
        const hit = !q || e.textContent.toLowerCase().includes(q);
        e.hidden = !hit;
        if (hit) shown++;
      });
      bands.forEach((band) => {
        let group = null;
        let any = false;
        const flush = () => {
          if (group) group.hidden = !any;
        };
        [...band.children].forEach((child) => {
          if (child.classList.contains("group")) {
            flush();
            group = child;
            any = false;
          } else if (child.classList.contains("entry") && !child.hidden) {
            any = true;
          }
        });
        flush();
        band.hidden = ![...band.querySelectorAll(".entry")].some((e) => !e.hidden);
      });
      if (count) count.textContent = q ? `${shown} of ${total}` : `${total} entries`;
    };
    input.addEventListener("input", apply);
    apply();
  }

  function markNav() {
    const here = (location.pathname.split("/").pop() || "index.html").toLowerCase();
    document.querySelectorAll(".nav a[href]").forEach((a) => {
      const href = a.getAttribute("href").replace(/^\.\//, "").toLowerCase();
      if (href === here) a.setAttribute("aria-current", "page");
      else a.removeAttribute("aria-current");
    });
  }

  function boot() {
    paintThemeButton();
    markNav();
    wireFilter();
    alignGlyphs(document);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }

  document.addEventListener("htmx:afterRequest", (e) => {
    const xhr = e.detail && e.detail.xhr;
    if (!xhr || !xhr.responseText) return;
    const m = /<title>([^<]*)<\/title>/i.exec(xhr.responseText);
    if (m) document.title = m[1];
  });

  document.addEventListener("htmx:afterSettle", () => {
    markNav();
    wireFilter();
    alignGlyphs(document);
    if (typeof window.moonpoolBoot === "function") window.moonpoolBoot();
  });

  prefersDark.addEventListener("change", paintThemeButton);
})();
