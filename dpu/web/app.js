/* ==========================================================================
   DPU dashboard client.
   Polls /api/telemetry, renders the scope, node manager, readouts and ticker.
   No dependencies: the engine serves these three files straight from memory.
   ========================================================================== */
"use strict";

const POLL_MS = 250;
const TRACE_LEN = 180;          // ~45s of history at 250ms

/* Traces rendered on the scope. `scale` normalises wildly different units
   (bytes/sec vs page faults/sec) onto one shared axis. */
const TRACES = [
  { key: "disk_read_bps",  label: "DISK READ",   color: "#3dffa8", unit: "MB/s", scale: 1048576, decimals: 2 },
  { key: "disk_write_bps", label: "DISK WRITE",  color: "#45d9f0", unit: "MB/s", scale: 1048576, decimals: 2 },
  { key: "pool_sat",       label: "SATURATION",  color: "#ffb454", unit: "%",    scale: 1,       decimals: 1, fromPool: true },
  { key: "page_faults_per_sec", label: "PAGE FAULTS", color: "#b98bff", unit: "/s", scale: 1,    decimals: 0 },
  { key: "gpu_shared",     label: "GPU SHARED",  color: "#ff4d6a", unit: "MB",   scale: 1048576, decimals: 0 },
];

const state = {
  traces: {},          // key -> number[] ring buffer
  nodes: [],
  power: "xhigh",
  split: true,
  engine: {},
  tickerItems: [],
  scrollX: 0,
  lastSampleAt: 0,
  st: null,            // smoothed traces, to stop the graph jittering
};

/* ------------------------------- helpers -------------------------------- */
const $ = (id) => document.getElementById(id);

function fmtBytes(n) {
  const units = ["B", "KB", "MB", "GB", "TB"];
  let v = n, i = 0;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
  return `${v < 10 && i > 0 ? v.toFixed(1) : Math.round(v)} ${units[i]}`;
}

function fmtCount(n) {
  if (n >= 1e9) return (n / 1e9).toFixed(1) + "B";
  if (n >= 1e6) return (n / 1e6).toFixed(1) + "M";
  if (n >= 1e3) return (n / 1e3).toFixed(1) + "K";
  return Math.round(n).toString();
}

function fmtUptime(ms) {
  const s = Math.floor(ms / 1000);
  const h = String(Math.floor(s / 3600)).padStart(2, "0");
  const m = String(Math.floor((s % 3600) / 60)).padStart(2, "0");
  const sec = String(s % 60).padStart(2, "0");
  return `${h}:${m}:${sec}`;
}

function fmtClock(ms) {
  const d = new Date(ms);
  return [d.getHours(), d.getMinutes(), d.getSeconds()]
    .map((n) => String(n).padStart(2, "0")).join(":");
}

/* Lightweight exponential smoothing. Raw PDH samples are spiky enough that an
   unsmoothed line reads as noise rather than as a trend. */
function smooth(prev, next) {
  if (prev == null) return next;
  return prev * 0.62 + next * 0.38;
}

/* --------------------------------- data ---------------------------------- */
async function poll() {
  try {
    const res = await fetch("/api/telemetry", { cache: "no-store" });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    applyData(await res.json());
    state.lastSampleAt = Date.now();
  } catch (err) {
    setTicker("link lost — retrying engine", "warn");
  }
}

function applyData(d) {
  state.power = d.engine.power;
  state.split = d.engine.split;
  state.engine = d.engine;

  const c = d.counters || {};
  const poolSat = (d.pool && d.pool.saturation) || 0;
  const gpuShared = sumGpuShared(c);

  // GPU adapter counters arrive keyed by full path; fold them into one series.
  const values = {
    disk_read_bps: c.disk_read_bps || 0,
    disk_write_bps: c.disk_write_bps || 0,
    pool_sat: poolSat,
    page_faults_per_sec: c.page_faults_per_sec || 0,
    gpu_shared: gpuShared,
  };

  for (const t of TRACES) {
    const arr = (state.traces[t.key] ||= []);
    arr.push(values[t.key] || 0);
    if (arr.length > TRACE_LEN) arr.shift();
  }

  renderReadouts(d, gpuShared);
  renderNodes(d);
  renderTicker(d);
  renderControls();
}

function sumGpuShared(counters) {
  let total = 0;
  for (const [k, v] of Object.entries(counters)) {
    if (k.startsWith("gpu_")) total += v;
  }
  return total;
}

/* ------------------------------ readouts --------------------------------- */
function renderReadouts(d, gpuShared) {
  const c = d.counters || {};
  const sat = (d.pool && d.pool.saturation) || 0;

  $("m-read").textContent = ((c.disk_read_bps || 0) / 1048576).toFixed(2);
  $("m-write").textContent = ((c.disk_write_bps || 0) / 1048576).toFixed(2);
  $("m-sat").textContent = sat.toFixed(1);
  $("m-gpu").textContent = (gpuShared / 1048576).toFixed(0);
  $("m-pf").textContent = fmtCount(c.page_faults_per_sec || 0);
  $("m-mem").textContent = ((c.mem_available || 0) / 1073741824).toFixed(2);

  const bar = $("m-sat-bar");
  bar.style.width = `${Math.min(sat, 100).toFixed(1)}%`;
  bar.className = "meter-fill" + (sat > 90 ? " hot" : sat > 70 ? " warn" : "");

  $("ro-uptime").textContent = fmtUptime(d.uptimeMs || 0);
  $("ro-agents").textContent = (d.total && d.total.agents) || 0;
  $("ro-mode").textContent = d.engine.power || "xHIGH";
  $("clock").textContent = fmtClock(Date.now());
  $("sample-rate").textContent = `${POLL_MS}ms · PDH`;

  if (d.pool) {
    $("ro-pool").textContent = d.pool.path;
  }

  // Capacity-pool state. `buffer` is null when P:\ could not be opened, which
  // is reported plainly rather than being rendered as a pool of zeroes.
  const buf = d.buffer;
  if (buf) {
    $("buf-ceiling").textContent = fmtBytes(buf.ceiling);
    $("buf-used").textContent = fmtBytes(buf.used);
    $("buf-alloc").textContent = fmtBytes(buf.allocated);
    $("buf-latency").textContent = buf.latencyMs > 0
      ? `${buf.latencyMs.toFixed(2)} ms`
      : "idle";
    const sparseEl = $("buf-sparse");
    sparseEl.textContent = buf.sparse ? "YES" : "UNSUPPORTED";
    sparseEl.className = buf.sparse ? "" : "warn";
    $("pool-note").textContent =
      `${buf.reads} reads / ${buf.writes} writes this session`;
  } else {
    $("buf-ceiling").textContent = "OFFLINE";
    $("buf-used").textContent = "--";
    $("buf-alloc").textContent = "--";
    $("buf-latency").textContent = "--";
    $("buf-sparse").textContent = "--";
    $("pool-note").textContent = "P:\\ capacity pool unavailable";
  }
}

/* ----------------------------- node manager ------------------------------ */
function renderNodes(d) {
  const list = $("node-list");
  const procs = (d.procs || []).slice(0, 28);

  // Rebuild only when the node set actually changed; otherwise patch text in
  // place so the list does not thrash scroll position every 250ms.
  const sig = procs.map((p) => `${p.pid}:${p.name}`).join("|");
  if (sig !== list.dataset.sig) {
    list.dataset.sig = sig;
    list.innerHTML = "";
    for (let i = 0; i < procs.length; i++) {
      const el = document.createElement("div");
      el.className = "node-row";
      el.innerHTML =
        `<span class="col-node"></span>` +
        `<span><span class="role-tag"></span></span>` +
        `<span class="col-num" data-f="ws"></span>` +
        `<span class="col-num" data-f="pf"></span>` +
        `<span class="col-num" data-f="cpu"></span>`;
      list.appendChild(el);
    }
  }

  const rows = list.children;
  for (let i = 0; i < Math.min(rows.length, procs.length); i++) {
    const p = procs[i];
    const row = rows[i];
    row.querySelector(".col-node").textContent = p.name;
    row.querySelector(".role-tag").textContent = p.role;
    row.querySelector(".role-tag").className = `role-tag ${p.role}`;
    row.querySelector('[data-f="ws"]').textContent = fmtBytes(p.ws);
    row.querySelector('[data-f="pf"]').textContent = fmtCount(p.pf);
    row.querySelector('[data-f="cpu"]').textContent = `${(p.cpu || 0).toFixed(0)}%`;
  }

  $("node-total").textContent = `${(d.total && d.total.processes) || 0} NODES`;
  $("sum-agent").textContent = (d.total && d.total.agents) || 0;
  $("sum-gfx").textContent = (d.total && d.total.graphics) || 0;
  $("sum-sys").textContent = Math.max(0, ((d.total && d.total.processes) || 0) -
                                        ((d.total && d.total.agents) || 0) -
                                        ((d.total && d.total.graphics) || 0));
}

/* ------------------------------ controls --------------------------------- */
function renderControls() {
  for (const btn of document.querySelectorAll("#power-group .ctl-btn")) {
    btn.classList.toggle("active", btn.dataset.power === state.power);
  }
  const toggle = $("split-toggle");
  toggle.setAttribute("aria-pressed", state.split ? "true" : "false");
  $("split-text").textContent = state.split ? "ON" : "OFF";
  $("prefetch-value").textContent = state.engine.prefetch ?? "-";
}

async function sendControl(params) {
  try {
    await fetch("/api/control", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams(params).toString(),
    });
    await poll();
  } catch {
    setTicker("control write failed", "warn");
  }
}

function wireControls() {
  $("power-group").addEventListener("click", (e) => {
    const btn = e.target.closest(".ctl-btn");
    if (!btn) return;
    sendControl({ power: btn.dataset.power });
    setTicker(`power mode -> ${btn.dataset.power.toUpperCase()}`, "new");
  });

  $("split-toggle").addEventListener("click", () => {
    const next = !(state.split);
    sendControl({ split: next ? "1" : "0" });
    setTicker(`multi-agent split -> ${next ? "ENABLED" : "DISABLED"}`, "new");
  });
}

/* -------------------------------- ticker ---------------------------------- */
let tickerVersion = 0;
function setTicker(text, kind = "new") {
  const track = $("ticker");
  const el = document.createElement("span");
  el.className = `tick-${kind}`;
  el.textContent = `${fmtClock(Date.now())}  ${text}`;
  track.insertBefore(el, track.firstChild);
  state.tickerItems.push(el);
  while (state.tickerItems.length > 40) state.tickerItems.shift().remove();
  // Restart the marquee so a new item scrolls in from the right edge.
  state.scrollX = 0;
}

function tickTicker() {
  const track = $("ticker");
  if (!track) return;
  const w = track.scrollWidth;
  const win = track.parentElement.clientWidth;
  if (w <= win) { track.style.transform = "none"; return; }
  state.scrollX += 0.55;
  if (state.scrollX > w) state.scrollX = -win;
  track.style.transform = `translateX(${-state.scrollX}px)`;
}

function renderTicker(d) {
  const sat = (d.pool && d.pool.saturation) || 0;
  const c = d.counters || {};
  const avail = (c.mem_available || 0) / 1073741824;

  // Rotating status text: only announce periodically so the ticker stays
  // readable instead of scrolling a new line every 250ms. The first banner
  // must fire immediately, hence the `!state.lastBanner` branch.
  const now = Date.now();
  if (!state.lastBanner || now - state.lastBanner > 9000) {
    if (avail < 1.0) {
      setTicker(`memory pressure — ${avail.toFixed(2)} GB available`, "warn");
    } else if (sat > 90) {
      setTicker(`P:\\ Drive DPU Buffer nearly full — ${sat.toFixed(1)}%`, "warn");
    } else if ((d.total && d.total.agents) > 0) {
      setTicker(`P:\\ Drive DPU Buffer is being utilized — ${d.total.agents} agent node(s) resident`, "new");
    } else {
      setTicker(`P:\\ Drive DPU Buffer standing by — ${d.total ? d.total.processes : 0} nodes tracked`, "new");
    }
    state.lastBanner = now;
  }
}

/* --------------------------------- scope ---------------------------------- */
const canvas = () => $("scope");

function fitCanvas() {
  const cv = canvas();
  if (!cv) return null;
  const dpr = window.devicePixelRatio || 1;
  const r = cv.getBoundingClientRect();
  if (r.width === 0 || r.height === 0) return null;
  cv.width = Math.round(r.width * dpr);
  cv.height = Math.round(r.height * dpr);
  const ctx = cv.getContext("2d");
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  return { ctx, w: r.width, h: r.height };
}

/* Draw the scope as stacked small multiples: one band per metric, each with its
   own auto-scaled axis.
   A single shared y-axis was tried first and was unusable — page faults peak in
   the tens of thousands while disk throughput lives in the hundreds of KB/s, so
   one shared ceiling flattened every trace except the spikiest to a straight
   line. Per-band scaling keeps each metric legible; the live value in each
   band header is what carries the absolute number. */
function drawScope() {
  const fit = fitCanvas();
  if (!fit) return;
  const { ctx, w, h } = fit;

  ctx.clearRect(0, 0, w, h);
  ctx.font = "9px 'JetBrains Mono', Consolas, monospace";

  const padL = 96, padR = 74, padT = 6, padB = 6;
  const gw = w - padL - padR;
  const gh = h - padT - padB;
  if (gw <= 0 || gh <= 0) return;

  const bands = TRACES.length;
  const bandH = gh / bands;

  for (let bi = 0; bi < bands; bi++) {
    const t = TRACES[bi];
    const arr = state.traces[t.key] || [];
    const bandTop = padT + bi * bandH;
    const baseY = bandTop + bandH - 1;   // trace baseline

    // band background + separator
    ctx.fillStyle = bi % 2 ? "rgba(12, 20, 26, 0.55)" : "rgba(8, 13, 18, 0.55)";
    ctx.fillRect(padL, bandTop, gw, bandH - 1);

    // scale this band from its own windowed peak
    let peak = 1;
    for (const v of arr) {
      const scaled = Math.abs(v) / t.scale;
      if (scaled > peak) peak = scaled;
    }
    const top = niceCeil(peak * 1.2);
    const innerH = bandH - 10;

    // gridlines within the band
    ctx.strokeStyle = "#101c22";
    ctx.lineWidth = 1;
    for (let g = 1; g <= 2; g++) {
      const y = Math.round(baseY - (innerH * g) / 3) + 0.5;
      ctx.beginPath();
      ctx.moveTo(padL, y);
      ctx.lineTo(padL + gw, y);
      ctx.stroke();
    }

    // vertical time grid, shared across bands
    ctx.strokeStyle = "#0d171c";
    for (let i = 0; i <= 6; i++) {
      const x = Math.round(padL + (gw * i) / 6) + 0.5;
      ctx.beginPath();
      ctx.moveTo(x, bandTop);
      ctx.lineTo(x, bandTop + bandH - 1);
      ctx.stroke();
    }

    // band frame
    ctx.strokeStyle = "#1a2e37";
    ctx.strokeRect(padL + 0.5, bandTop + 0.5, gw, bandH - 2);

    // label, left
    ctx.fillStyle = t.color;
    ctx.textAlign = "left";
    ctx.textBaseline = "middle";
    ctx.font = "9px 'JetBrains Mono', Consolas, monospace";
    ctx.fillText(t.label, 8, bandTop + bandH / 2 - 5);

    // live value, right
    const cur = arr.length ? arr[arr.length - 1] / t.scale : 0;
    ctx.font = "11px 'JetBrains Mono', Consolas, monospace";
    ctx.fillStyle = cur > 0 ? t.color : "#38505a";
    ctx.textAlign = "right";
    ctx.fillText(fmtScaled(cur, t.decimals), w - 10, bandTop + bandH / 2 - 5);

    ctx.font = "8px 'JetBrains Mono', Consolas, monospace";
    ctx.fillStyle = "#38505a";
    ctx.textAlign = "left";
    ctx.fillText(t.unit, 8, bandTop + bandH / 2 + 7);

    // ceiling annotation
    ctx.textAlign = "right";
    ctx.fillText(top >= 100 ? Math.round(top) : top.toFixed(top < 10 ? 1 : 0),
                 padL + gw - 4, bandTop + 9);
  }

  // traces, drawn after all backgrounds so no band clips its neighbour
  for (let bi = 0; bi < bands; bi++) {
    const t = TRACES[bi];
    const arr = state.traces[t.key] || [];
    if (arr.length < 2) continue;

    const bandTop = padT + bi * bandH;
    const baseY = bandTop + bandH - 1;
    const innerH = bandH - 10;

    let peak = 1;
    for (const v of arr) {
      const scaled = Math.abs(v) / t.scale;
      if (scaled > peak) peak = scaled;
    }
    const top = niceCeil(peak * 1.2);

    ctx.lineJoin = "round";
    ctx.strokeStyle = t.color + "2e";
    ctx.lineWidth = 3;
    strokeBand(ctx, arr, t, padL, baseY, gw, innerH, top);

    ctx.strokeStyle = t.color;
    ctx.lineWidth = 1.3;
    strokeBand(ctx, arr, t, padL, baseY, gw, innerH, top);

    // head dot
    const last = arr[arr.length - 1] / t.scale;
    const hy = baseY - innerH * Math.min(last / top, 1);
    ctx.fillStyle = t.color;
    ctx.beginPath();
    ctx.arc(padL + gw - 1, hy, 2.2, 0, Math.PI * 2);
    ctx.fill();
  }

  // time axis caption
  ctx.fillStyle = "#38505a";
  ctx.font = "8px 'JetBrains Mono', Consolas, monospace";
  ctx.textAlign = "left";
  ctx.textBaseline = "bottom";
  ctx.fillText(`-${(TRACE_LEN * POLL_MS / 1000).toFixed(0)}s`, padL + 2, padT + gh);
  ctx.textAlign = "right";
  ctx.fillText("NOW", padL + gw - 2, padT + gh);
}

function strokeBand(ctx, arr, t, padL, baseY, gw, innerH, top) {
  ctx.beginPath();
  const step = gw / (TRACE_LEN - 1);
  const offset = TRACE_LEN - arr.length;
  for (let i = 0; i < arr.length; i++) {
    const x = padL + (offset + i) * step;
    const y = baseY - innerH * Math.min(Math.abs(arr[i]) / t.scale / top, 1);
    if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
  }
  ctx.stroke();
}

function fmtScaled(v, decimals) {
  if (v >= 1000) return Math.round(v).toLocaleString();
  return v.toFixed(decimals);
}

/** Round up to the nearest 1/2/5 x 10^n. */
function niceCeil(v) {
  if (v <= 0) return 1;
  const exp = Math.floor(Math.log10(v));
  const base = Math.pow(10, exp);
  const n = v / base;
  let m;
  if (n <= 1) m = 1;
  else if (n <= 2) m = 2;
  else if (n <= 5) m = 5;
  else m = 10;
  return m * base;
}

function syncLegend() {
  // Legend was replaced by per-band labels drawn on the scope itself.
}

/* --------------------------------- boot ----------------------------------- */
function boot() {
  wireControls();
  poll();
  setInterval(poll, POLL_MS);
  setInterval(drawScope, 1000 / 30);   // scope redraws smoother than the poll rate
  setInterval(tickTicker, 1000 / 30);
  window.addEventListener("resize", drawScope);
  setTicker("engine handshake complete", "new");
  drawScope();
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", boot);
} else {
  boot();
}