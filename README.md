# CW Practice

An [Omarchy](https://omarchy.org/) shell plugin for amateur radio operators
practicing Morse code (CW) copy. Sends random characters as an audio sidetone
and reveals what was sent only after a selectable delay — so you copy by ear
first, then check yourself.

## Features

- **Start/Pause** — one button; the bar pill lights up while a run is active.
- **Character selection** — letters, numbers, and punctuation as toggleable
  grids (with All/None per group).
- **Speed** — 5–40 WPM, single-slider PARIS timing (dit = 1.2/WPM seconds).
- **Reveal delay** — 0–5 s in 0.5 s steps. Characters appear in the history
  only after the delay, so you're not relying on instantly seeing them.
- **History** — received characters wrap across the panel width; spaces mark
  word gaps. Clearable.
- **Word gaps** — toggleable: occasionally a 7-dit pause and a space, like
  words in real text.
- **Sidetone** — 400–800 Hz tone and volume sliders.
- **Persistent settings** — everything survives shell restarts.
- **Live settings** — speed, tone, volume, word gaps, and character
  selection changes apply on the next character while a run is active
  (no restart, no gap in the audio). The reveal delay applies immediately
  to characters not yet shown.

## How it works

`Panel.qml` runs `cw_player.py` as a long-lived child process. The player
generates the sidetone with proper PARIS timing, streams raw PCM to `pacat`,
and prints each character to stdout as its audio finishes playing. The panel
queues each reported character and reveals it into the history after the
configured delay.

While a run is active, settings changes are sent to the player over stdin as
`SET key=value` lines (wpm, tone, volume, pool, word-gaps); the player applies
them at the next character boundary, so the audio never restarts. Delay
changes are panel-side and apply immediately to unrevealed characters.

## State

Settings live at `~/.local/state/omarchy/cwpractice/state.json` (read with a
size-bounded, symlink- and FIFO-safe `dd` process; written atomically via
`mktemp` + `mv`).

## IPC

The plugin registers IPC functions:

```
omarchy-shell crueber.cwpractice open     # open the panel
omarchy-shell crueber.cwpractice start    # start practice
omarchy-shell crueber.cwpractice stop     # pause practice
omarchy-shell crueber.cwpractice history  # print revealed characters
omarchy-shell crueber.cwpractice set wpm 25           # live-set a value
omarchy-shell crueber.cwpractice set pool ABC123     # live-set the pool
omarchy-shell crueber.cwpractice set delay 2000      # reveal delay (ms)
omarchy-shell crueber.cwpractice set tone 650        # also: volume, word-gaps
```

## Development

- QML files hot-reload on save; after editing `Model.js` or `cw_player.py`,
  run `omarchy restart shell`.
- `Model.js` is pure JS — its state parsing/clamping is testable with any JS
  runtime.
- `PATTERNS` in `Model.js` and `MORSE` in `cw_player.py` MUST stay in sync.
- Validate: `omarchy plugin validate ~/.config/omarchy/plugins/crueber.cwpractice`
- Check for load errors: `journalctl --user` (grep for the plugin id).

## Requirements

`python3`, `pacat` (PulseAudio tools) — both ship with Omarchy.
