# peerdrop-cli headless agent mode — design

**Date:** 2026-06-22
**Status:** approved (user, inline)

## Problem

`peerdrop-cli` wraps a process in a PTY and flattens its terminal output into
chat messages. That works for line-based programs (a shell, a REPL). It does
**not** work for a full-screen TUI like `claude`: the TUI paints with absolute
cursor addressing, an alternate screen buffer, and box-drawing — none of which
survives being linearised into chat bubbles (borders collapse to `___`, the
banner scatters). Stripping the positioning escapes is what destroys the layout;
a chat bubble has no terminal grid to paint on.

This is a category mismatch, not a stripping bug. The right way to make `claude`
a chat peer is its **headless mode** (`claude -p`), which emits plain text.

## Goal

Text your phone → `claude` answers as a clean chat bubble, with conversation
context preserved across turns — using `claude -p` instead of its TUI.

## Design

| # | Decision | Choice |
|---|----------|--------|
| 1 | Activation | `--agent` flag. `peerdrop-cli --name "mac · claude" --agent` (base command defaults to `claude`), or `--agent -- claude --model …` for custom base args. No `--agent` → behaviour unchanged. |
| 2 | Architecture | New `AgentBridge`, alongside `ProcessBridge`, both conforming to a `MessageBridge` protocol. `AgentSession` depends on the protocol, so trust-gating/wiring is unchanged. `Entry` selects the bridge from `--agent`. |
| 3 | Per-message flow | Incoming chat msg → run `claude -p "<msg>" --continue --output-format text --permission-mode <mode>` in the cwd → capture stdout → emit one clean chat bubble (batch). |
| 4 | Continuity | `--continue` (resume the most recent conversation in the cwd) for v1. Follow-up: pin a `--session-id` for isolation. |
| 5 | **Safety** | Default `--permission-mode plan` → claude does **not** execute edits or run commands (those auto-deny with no TTY). ⚠️ **It DOES still run read-only tools (Read/Bash `cat`/Grep/WebFetch) with no prompt — so a paired peer can have the agent read & return host file contents (an exfiltration surface).** Plan stays the default because reading project context to answer is the feature's value; the CLI banner states this explicitly and the threat model is "control your OWN trusted device's agent." Opt-in `--agent-yolo` → `--permission-mode bypassPermissions` additionally permits edits + command execution. |

**Other:** messages are processed serially (one `claude` at a time, ordered);
non-zero exit / no output → a short error bubble (never silent); cwd = where
`peerdrop-cli` was launched.

**Explicitly v1-only (follow-ups):** token streaming + tool-activity visibility
(`--output-format stream-json`); a typing/"thinking…" indicator while claude
runs; per-instance session isolation via `--session-id`.

## Files

- `MessageBridge.swift` — protocol (onMessage/onExit/start/send/terminate).
- `AgentBridge.swift` — headless claude runner (new).
- `ProcessBridge.swift` — conform to `MessageBridge`.
- `AgentSession.swift` — depend on `MessageBridge`, not the concrete bridge.
- `CLIOptions.swift` — `--agent`, `--agent-yolo`; default command = `claude`
  when `--agent` and no explicit `-- cmd`.
- `Entry.swift` — select `AgentBridge` vs `ProcessBridge`.

## Verification

- Unit: `AgentBridge.arguments(...)` builds the right argv; the run→capture→emit
  pipeline emits a fake command's stdout (no real `claude` call in tests).
- Integration: drive `AgentBridge` with a stub command; assert the bubble.
- Device: `peerdrop-cli --agent`, message the phone, confirm a clean reply.
- Foundation already verified: `claude -p "…" --output-format text` → clean text.
