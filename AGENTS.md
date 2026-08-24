# AGENTS.md

Guidance for agents (and humans) working on this Omarchy shell plugin.

## What this is

A `bar-widget` plugin for the Omarchy shell (Quickshell) that sends Morse
code (CW) as an audio sidetone for receiving practice. A "CW" pill in the
bar opens the practice panel; characters are revealed into a history only
after a configurable delay so the operator copies by ear first.

## Layout

| File | Role |
|------|------|
| `manifest.json` | Plugin manifest (id, kinds, entry points, widget metadata) |
| `BarWidget.qml` | Bar pill (CW label), panel lifecycle, and IPC |
| `Panel.qml` | Popup panel: practice controls, delayed-reveal history, settings |
| `Model.js` | Pure logic: char groups, bounds, state (de)serialization — no QML imports |
| `cw_player.py` | Sidetone generator: PARIS timing → raw PCM → `pacat`, stdout protocol |
| `README.md` | User-facing docs |

## Development loop

- QML files under the plugin dir hot-reload on save.
- **`Model.js` does not reliably hot-reload.** The shell caches compiled JS
  imports — after editing it, run `omarchy restart shell`. `cw_player.py`
  only takes effect on the next player launch, so restart the shell (or
  stop/start practice) after editing it.
- Validate before committing: `omarchy plugin validate <plugin-dir>`.
- Check for load errors: `journalctl --user` (grep for the plugin id).
- Quick runtime checks without touching the panel:
  `omarchy-shell crueber.cwpractice start|stop|history|set <key> <value>`.

## Hard rules

### Bound every file read (memory gating)

The shell is a single long-lived process. Never read a file into it without
a size bound. Read `state.json` only with the bounded `dd` `Process` in
`Panel.qml` (symlink- and FIFO-safe, byte-capped, deadline-capped) — see the
rpgdice plugin's AGENTS.md for the rationale. Never use `FileView` for
user-writable files.

### Persistence

- State lives at `~/.local/state/omarchy/cwpractice/state.json`.
- Write via `mktemp` + `mv -f` (atomic, symlink-safe), using
  `Util.execDetached` with `Util.shellQuote` — never interpolate raw
  strings into a shell command.

### Theme

Use `qs.Ui` / `qs.Commons` components and `Color` / `Style` tokens. Never
hardcode colors or sizes; the active theme drives them.

### Sanitize rendered text

Run any user-influenced string through `Model.plainText` (strips `<>&`) and
set `textFormat: Text.PlainText`.

## Plugin-specific invariants

- **`PATTERNS` in `Model.js` and `MORSE` in `cw_player.py` MUST stay in
  sync.** Adding a character to one table requires the other.
- **PARIS timing**: dit duration is `1.2 / WPM` seconds. Every element
  (tone and gap) derives from that single constant; don't introduce a
  second timing source.
- **stdout protocol** (player → panel): one line per sent character, as its
  audio finishes playing; a trailing space means a word gap follows.
- **stdin protocol** (panel → player): `SET key=value` lines (`wpm`, `tone`,
  `volume`, `pool`, `word-gaps`), applied at the next character boundary.
  EOF means the parent is gone — the player must exit.
- Settings changes must apply **live** during a run (next character), not by
  restarting the player. The reveal delay is panel-side only.
- The player paces itself against wall-clock playback time so `pacat`'s
  buffering can't make it outrun the audio.
- `historyText` is capped at `MAX_HISTORY`. The reveal queue is bounded
  naturally (delay × send rate); if you add an unbounded producer, cap it
  explicitly the same way.

## Testing

`Model.js` is pure JS (no QML imports) — test with any JS runtime. Its
state parsing/clamping and the Morse table coverage have a contract test
run with `node`. `cw_player.py` is testable standalone with `--volume 0`
(silent): assert per-character print timestamps against PARIS math. The
QML is verified by loading it in the shell and checking `journalctl --user`.
