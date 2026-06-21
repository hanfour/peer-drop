let term, fit, ws, backoff = 1000, currentSession = null, reconnect = false;
let ctrlActive = false;

// Detect touch/coarse-pointer devices early and add body class for CSS
if (window.matchMedia("(pointer: coarse)").matches) {
  document.body.classList.add("touch");
}

// --- byte helpers ---

function sendBytes(arr) {            // arr = array of byte values
  if (!ws || ws.readyState !== 1) return;
  const f = new Uint8Array(arr.length + 1); f[0] = 0x00; f.set(arr, 1);
  ws.send(f);
}

const SEQ = {
  esc:   [0x1b],
  tab:   [0x09],
  stab:  [0x1b, 0x5b, 0x5a],   // ESC [ Z — Shift+Tab / back-tab
  up:    [0x1b, 0x5b, 0x41],   // ESC [ A
  down:  [0x1b, 0x5b, 0x42],   // ESC [ B
  right: [0x1b, 0x5b, 0x43],   // ESC [ C
  left:  [0x1b, 0x5b, 0x44],   // ESC [ D
  ctrlc: [0x03],
};

// --- terminal setup ---

function setupTerm() {
  if (term) return;
  term = new Terminal({ cursorBlink: true, fontFamily: "Menlo, monospace" });
  fit = new FitAddon.FitAddon();
  term.loadAddon(fit);
  term.open(document.getElementById("term"));
  term.onData((d) => {
    if (!ws || ws.readyState !== 1) return;
    if (ctrlActive && d.length >= 1) {
      const c = d.charCodeAt(0);
      // Transform to control code: letters and most printable chars → c & 0x1f
      // (e.g. 'c'→0x03, 'a'→0x01, 'z'→0x1a)
      sendBytes([(c & 0x1f)]);
      ctrlActive = false;
      document.getElementById("ctrlkey").classList.remove("active");
      return;
    }
    const bytes = new TextEncoder().encode(d);
    sendBytes(Array.from(bytes));
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
  backoff = 1000;
  document.getElementById("picker").style.display = "none";
  document.getElementById("term").style.display = "block";
  document.getElementById("switch").style.display = "block";
  setupTerm(); term.reset(); fit.fit();
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

// --- logout ---

// POST /logout is auth-gated and origin-checked (SameSite=Strict session cookie),
// so no separate CSRF token is needed for logout itself.
document.getElementById("logout-btn").addEventListener("click", async () => {
  try {
    const res = await fetch("/logout", { method: "POST", credentials: "same-origin" });
    // Server responds with 303 → /login; after the POST resolves, redirect manually
    // so the browser lands cleanly on the login page regardless of redirect-following.
    window.location = "/login";
  } catch (_) {
    window.location = "/login";
  }
});

// --- key bar wiring ---

// Ctrl sticky modifier
document.getElementById("ctrlkey").addEventListener("pointerdown", (e) => {
  e.preventDefault();
  ctrlActive = !ctrlActive;
  document.getElementById("ctrlkey").classList.toggle("active", ctrlActive);
  if (term) term.focus();
});

// All [data-seq] buttons
document.querySelectorAll("#keybar [data-seq]").forEach((btn) => {
  btn.addEventListener("pointerdown", (e) => {
    e.preventDefault();   // prevent focus steal from terminal
  });
  btn.addEventListener("click", (e) => {
    const seq = SEQ[btn.dataset.seq];
    if (seq) sendBytes(seq);
    // Clear Ctrl sticky state when any key-bar button is tapped
    if (ctrlActive) {
      ctrlActive = false;
      document.getElementById("ctrlkey").classList.remove("active");
    }
    if (term) term.focus();
  });
});

// --- global event wiring ---

document.getElementById("switch").onclick = showPicker;
setInterval(() => { if (ws && ws.readyState === 1) ws.send(new Uint8Array([0x02])); }, 30000);  // keepalive
loadPresets();
