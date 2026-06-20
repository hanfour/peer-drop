let term, fit, ws, backoff = 1000, currentSession = null, reconnect = false;

function setupTerm() {
  if (term) return;
  term = new Terminal({ cursorBlink: true, fontFamily: "Menlo, monospace" });
  fit = new FitAddon.FitAddon();
  term.loadAddon(fit);
  term.open(document.getElementById("term"));
  term.onData((d) => {
    if (!ws || ws.readyState !== 1) return;
    const bytes = new TextEncoder().encode(d);
    const f = new Uint8Array(bytes.length + 1); f[0] = 0x00; f.set(bytes, 1);
    ws.send(f);
  });
  term.onResize(() => sendResize());
  window.addEventListener("resize", () => { if (fit) { fit.fit(); sendResize(); } });
}

function sendResize() {
  if (!ws || ws.readyState !== 1) return;
  const b = new Uint8Array(5);
  b[0] = 0x01; b[1] = term.cols >> 8; b[2] = term.cols & 0xff; b[3] = term.rows >> 8; b[4] = term.rows & 0xff;
  ws.send(b);
}

function connect(sessionId) {
  currentSession = sessionId; reconnect = true;
  document.getElementById("picker").style.display = "none";
  document.getElementById("term").style.display = "block";
  document.getElementById("switch").style.display = "block";
  setupTerm(); fit.fit();
  const proto = location.protocol === "https:" ? "wss" : "ws";
  ws = new WebSocket(`${proto}://${location.host}/ws/${sessionId}`);
  ws.binaryType = "arraybuffer";
  ws.onopen = () => { backoff = 1000; sendResize(); };
  ws.onmessage = (e) => { const u = new Uint8Array(e.data); if (u[0] === 0x00) term.write(u.slice(1)); };
  ws.onclose = () => {
    if (!reconnect) return;
    term.write("\r\n[disconnected — reconnecting…]\r\n");
    setTimeout(() => { if (reconnect) connect(currentSession); }, backoff);
    backoff = Math.min(backoff * 2, 15000);
  };
  ws.onerror = () => { try { ws.close(); } catch (_) {} };
}

function showPicker() {
  reconnect = false;
  if (ws) { try { ws.close(); } catch (_) {} ws = null; }
  document.getElementById("term").style.display = "none";
  document.getElementById("switch").style.display = "none";
  document.getElementById("picker").style.display = "block";
  loadPresets();
}

async function loadPresets() {
  const el = document.getElementById("presets"); el.textContent = "loading…";
  try {
    const res = await fetch("/api/sessions", { credentials: "same-origin" });
    if (!res.ok) { el.textContent = "failed to load sessions (" + res.status + ")"; return; }
    const data = await res.json();
    el.textContent = "";
    for (const p of data.presets) {
      const b = document.createElement("button");
      b.className = "preset";
      b.textContent = p.name;
      if (p.running) { const s = document.createElement("span"); s.className = "run"; s.textContent = "● running"; b.appendChild(s); }
      b.onclick = () => connect(p.id);
      el.appendChild(b);
    }
  } catch (e) { el.textContent = "error: " + e; }
}

document.getElementById("switch").onclick = showPicker;
setInterval(() => { if (ws && ws.readyState === 1) ws.send(new Uint8Array([0x02])); }, 30000);  // keepalive
loadPresets();
