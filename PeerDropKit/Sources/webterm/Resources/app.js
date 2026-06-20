const term = new Terminal({ cursorBlink: true, fontFamily: "Menlo, monospace" });
const fit = new FitAddon.FitAddon();
term.loadAddon(fit);
term.open(document.getElementById("term"));
fit.fit();

const sessionId = "shell";   // MVP: the default shell preset's tmux session
let ws, backoff = 1000;

function sendResize() {
  if (!ws || ws.readyState !== 1) return;
  const b = new Uint8Array(5);
  b[0] = 0x01;
  b[1] = term.cols >> 8; b[2] = term.cols & 0xff;
  b[3] = term.rows >> 8; b[4] = term.rows & 0xff;
  ws.send(b);
}

function connect() {
  const proto = location.protocol === "https:" ? "wss" : "ws";
  ws = new WebSocket(`${proto}://${location.host}/ws/${sessionId}`);
  ws.binaryType = "arraybuffer";
  ws.onopen = () => { backoff = 1000; sendResize(); };
  ws.onmessage = (e) => {
    const u = new Uint8Array(e.data);
    if (u[0] === 0x00) term.write(u.slice(1));   // data
  };
  ws.onclose = () => {
    term.write("\r\n[disconnected — reconnecting…]\r\n");
    setTimeout(connect, backoff);
    backoff = Math.min(backoff * 2, 15000);      // exponential backoff, max 15s
  };
  ws.onerror = () => { try { ws.close(); } catch (_) {} };
}

term.onData((d) => {                             // raw key passthrough
  if (!ws || ws.readyState !== 1) return;
  const bytes = new TextEncoder().encode(d);
  const f = new Uint8Array(bytes.length + 1); f[0] = 0x00; f.set(bytes, 1);
  ws.send(f);
});
window.addEventListener("resize", () => { fit.fit(); sendResize(); });
term.onResize(() => sendResize());
setInterval(() => { if (ws && ws.readyState === 1) ws.send(new Uint8Array([0x02])); }, 30000);  // keepalive

connect();
