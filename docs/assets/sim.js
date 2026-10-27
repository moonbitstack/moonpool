/* The pool, driven by the package compiled to JavaScript. Every number on the
   page — the areas, the counters, the refusals — comes back from
   assets/moonpool.js, which is this repository built for the browser. */

let engine = null;
let engineTried = false;
let lastTrace = null;
let cursor = 0;

const CONTROLS = [
  "size", "idle", "keep", "life", "rate", "hold", "fail", "cpu",
];

async function loadEngine() {
  if (engine || engineTried) return engine;
  engineTried = true;
  try {
    engine = await import("./moonpool.js");
  } catch (err) {
    console.warn("assets/moonpool.js is not built; the board stays empty.", err);
  }
  return engine;
}

function readControls() {
  const get = (id) => Number(document.getElementById(id)?.value ?? 0);
  return {
    size: get("size"),
    idle: get("idle"),
    keep: get("keep"),
    life: get("life"),
    rate: get("rate"),
    hold: get("hold"),
    fail: get("fail"),
    cpu: get("cpu"),
    breaker: document.getElementById("breaker")?.checked ? 1 : 0,
    burst: document.getElementById("burst")?.checked ? 1 : 0,
    ticks: 240,
    seed: 7,
  };
}

function spec(cfg) {
  return CONTROLS.concat(["breaker", "burst", "ticks", "seed"])
    .map((k) => `${k}=${cfg[k]}`)
    .join(",");
}

/* ---- the chart ------------------------------------------------------- */

function drawChart(trace) {
  const svg = document.getElementById("chart");
  if (!svg) return;
  const W = 900;
  const H = 300;
  const padL = 34;
  const padB = 24;
  const padT = 12;
  const ticks = trace.ticks;
  const n = ticks.length;
  const max = Math.max(
    trace.config.size > 0 ? trace.config.size : 1,
    ...ticks.map((t) => t.busy + t.idle)
  );
  const step = max <= 8 ? 1 : max <= 16 ? 2 : 5;
  const top = Math.ceil(max / step) * step;
  const x = (i) => padL + (i / Math.max(1, n - 1)) * (W - padL - 8);
  const y = (v) => H - padB - (v / top) * (H - padB - padT);

  let out = "";
  for (let v = 0; v <= top; v += step) {
    out += `<line class="grid-line" x1="${padL}" y1="${y(v)}" x2="${W - 8}" y2="${y(v)}"/>`;
    out += `<text x="${padL - 6}" y="${y(v) + 3}" text-anchor="end">${v}</text>`;
  }
  // idle first (stacked under busy), then busy on top
  const area = (key, cls) => {
    let d = `M${x(0)},${y(0)}`;
    for (let i = 0; i < n; i++) {
      const base = key === "busy" ? ticks[i].idle : 0;
      d += ` L${x(i)},${y(base + ticks[i][key])}`;
    }
    d += ` L${x(n - 1)},${y(0)} Z`;
    return `<path class="${cls}" d="${d}"/>`;
  };
  out += area("idle", "idle-area");
  out += area("busy", "busy-area");
  // refusal, a line on its own 0..1 scale
  let line = "";
  for (let i = 0; i < n; i++) {
    line += `${i === 0 ? "M" : "L"}${x(i)},${y(ticks[i].refusal * top)}`;
  }
  out += `<path class="refuse-line" d="${line}"/>`;
  out += `<line class="axis" x1="${padL}" y1="${y(0)}" x2="${W - 8}" y2="${y(0)}"/>`;
  out += `<text x="${padL}" y="${H - 6}">0 s</text>`;
  out += `<text x="${W - 8}" y="${H - 6}" text-anchor="end">${(n / 10).toFixed(1)} s</text>`;
  if (cursor >= 0 && cursor < n) {
    out += `<line x1="${x(cursor)}" y1="${padT}" x2="${x(cursor)}" y2="${y(0)}" stroke="var(--rope)" stroke-width="1" stroke-dasharray="3 3"/>`;
  }
  svg.innerHTML = out;
  svg.setAttribute("viewBox", `0 0 ${W} ${H}`);
}

/* ---- the board ------------------------------------------------------- */

function paintBoard(trace) {
  const t = trace.ticks[Math.min(cursor, trace.ticks.length - 1)] || { busy: 0, idle: 0 };
  const total = trace.totals;
  const set = (id, value, cls) => {
    const el = document.getElementById(id);
    if (!el) return;
    el.textContent = value;
    if (cls) el.className = cls;
  };
  set("b-busy", t.busy);
  set("b-idle", t.idle);
  set("b-shed", t.shed, t.shed > 0 ? "hot" : "");
  set("b-wait", t.wait, t.wait > 0 ? "hot" : "");
  set("b-refusal", (t.refusal * 100).toFixed(1) + "%", t.refusal > 0 ? "hot" : "cool");
  set("t-ready", total.ready);
  set("t-made", total.made);
  set("t-failed", total.failed, total.failed > 0 ? "hot" : "");
  set("t-wait", total.wait, total.wait > 0 ? "hot" : "");
  set("t-shed", total.shed, total.shed > 0 ? "hot" : "");
  set("t-stale", total.stale);
  set("t-evicted", total.evicted);
  set("t-closed", total.closed);
  set("t-peak", `${total.peakBusy} / ${total.peakIdle}`);

  // the lane board: one cell per slot the pool is allowed to fill
  const strip = document.getElementById("strip");
  if (strip) {
    const size = trace.config.size;
    let cells = "";
    for (let i = 0; i < size; i++) {
      const state = i < t.busy ? "busy" : i < t.busy + t.idle ? "idle" : "";
      cells += `<span class="chip ${state}" title="lane ${i + 1}">${i + 1}</span>`;
    }
    strip.innerHTML = cells;
  }
  const clock = document.getElementById("clock");
  if (clock) clock.textContent = (cursor / 10).toFixed(1) + " s";
}

function render() {
  if (!lastTrace) return;
  drawChart(lastTrace);
  paintBoard(lastTrace);
}

async function run() {
  const api = await loadEngine();
  const status = document.getElementById("sim-status");
  if (!api) {
    if (status) status.textContent = "the engine is not built in this checkout";
    return;
  }
  const cfg = readControls();
  try {
    lastTrace = JSON.parse(api.run(spec(cfg)));
  } catch (err) {
    if (status) status.textContent = "the run failed";
    return;
  }
  // Open on the busiest moment rather than the last, so the board has something to say.
  let best = 0;
  let bestSeen = -1;
  lastTrace.ticks.forEach((t, i) => {
    const seen = t.busy + t.idle;
    if (seen > bestSeen) {
      bestSeen = seen;
      best = i;
    }
  });
  cursor = best;
  const scrub = document.getElementById("scrub");
  if (scrub) {
    scrub.max = String(lastTrace.ticks.length - 1);
    scrub.value = String(cursor);
  }
  if (status) {
    const t = lastTrace.totals;
    status.textContent = `${t.ready} lent · ${t.made} made · ${t.wait} waited · ${t.shed} refused · ${t.evicted + t.stale} retired`;
  }
  render();
}

let timer = 0;
function schedule() {
  clearTimeout(timer);
  timer = setTimeout(run, 120);
}

function boot() {
  if (!document.getElementById("chart")) return;
  CONTROLS.forEach((id) => {
    const el = document.getElementById(id);
    if (!el) return;
    const out = document.getElementById("v-" + id);
    if (out) {
      const sync = () => {
        out.textContent = el.value + (id === "keep" || id === "life" ? " s" : id === "hold" ? " ms" : "");
      };
      el.addEventListener("input", sync);
      sync();
    }
    el.addEventListener("input", schedule);
    el.addEventListener("change", schedule);
  });
  ["breaker", "burst"].forEach((id) => {
    const el = document.getElementById(id);
    if (el) el.addEventListener("change", schedule);
  });
  const scrub = document.getElementById("scrub");
  if (scrub) {
    scrub.addEventListener("input", () => {
      cursor = Number(scrub.value);
      render();
    });
  }
  document.querySelectorAll("[data-preset]").forEach((b) => {
    b.addEventListener("click", () => {
      const p = JSON.parse(b.dataset.preset);
      Object.entries(p).forEach(([k, v]) => {
        const el = document.getElementById(k);
        if (!el) return;
        if (el.type === "checkbox") el.checked = !!v;
        else el.value = v;
        const out = document.getElementById("v-" + k);
        if (out) out.textContent = el.value;
      });
      run();
    });
  });
  run();
}

window.moonpoolBoot = boot;
window.addEventListener("resize", () => {
  clearTimeout(timer);
  timer = setTimeout(render, 150);
});

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", boot);
} else {
  boot();
}
