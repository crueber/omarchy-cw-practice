// Pure logic for the CW Practice plugin. No QML imports — plain JS so the
// same functions are shared between the bar widget and the panel.
//
// The Morse patterns here MUST stay in sync with MORSE in cw_player.py.

// Standard PARIS-timing patterns. "." is a dit, "-" is a dah.
var PATTERNS = {
  "A": ".-",     "B": "-...",  "C": "-.-.",  "D": "-..",
  "E": ".",      "F": "..-.",  "G": "--.",   "H": "....",
  "I": "..",     "J": ".---",  "K": "-.-",   "L": ".-..",
  "M": "--",     "N": "-.",    "O": "---",   "P": ".--.",
  "Q": "--.-",   "R": ".-.",   "S": "...",   "T": "-",
  "U": "..-",    "V": "...-",  "W": ".--",   "X": "-..-",
  "Y": "-.--",   "Z": "--..",
  "0": "-----",  "1": ".----", "2": "..---", "3": "...--",
  "4": "....-",  "5": ".....", "6": "-....", "7": "--...",
  "8": "---..",  "9": "----.",
  ".": ".-.-.-", ",": "--..--", "?": "..--..", "/": "-..-.",
  "=": "-...-",  "+": ".-.-.", "-": "-....-", ":": "---...",
  ";": "-.-.-.", "\"": ".-..-.", "@": ".--.-.", "'": ".----.",
  "!": "-.-.--", "&": ".-...",  "(": "-.--.",  ")": "-.--.-",
  "$": "...-..-"
}

// Selectable character groups, in display order.
var GROUPS = [
  { id: "letters", label: "Letters", chars: "ABCDEFGHIJKLMNOPQRSTUVWXYZ".split("") },
  { id: "numbers", label: "Numbers", chars: "0123456789".split("") },
  { id: "punct", label: "Punctuation", chars:
    [".", ",", "?", "/", "=", "+", "-", ":", ";", "\"", "@", "'", "!", "&", "(", ")", "$"] }
]

var ALL_CHARS = []
for (var g = 0; g < GROUPS.length; g++)
  ALL_CHARS = ALL_CHARS.concat(GROUPS[g].chars)

// ---- bounds ----

var MIN_WPM = 5, MAX_WPM = 40
var MIN_TONE = 400, MAX_TONE = 800
var MIN_VOLUME = 0, MAX_VOLUME = 100
var DELAY_STEP = 500, MAX_DELAY = 5000

// Keep the visible history bounded: the panel wraps it across its width,
// so this is a scroll of roughly the last few lines.
var MAX_HISTORY = 120

// Hard bounds on persisted state. The file is a tiny config blob, so anything
// beyond these limits is garbage — refusing to grow the in-memory model past
// them keeps a corrupt or oversized state.json from forcing unbounded
// allocation in the long-lived shell.
var MAX_STATE_BYTES = 65536
var STATE_READ_TIMEOUT_SECS = 5

// ---- state ----

var DEFAULT_STATE = {
  wpm: 15,
  delayMs: 1000,
  toneHz: 600,
  volume: 70,
  wordGaps: true,
  chars: GROUPS[0].chars.slice()
}

function clampInt(v, min, max, fallback) {
  var n = Math.round(Number(v))
  if (!isFinite(n)) n = fallback
  return Math.max(min, Math.min(max, n))
}

// Only known characters, de-duplicated, order irrelevant.
function sanitizeChars(list) {
  if (!Array.isArray(list)) return DEFAULT_STATE.chars.slice()
  var seen = {}
  var out = []
  for (var i = 0; i < list.length && out.length < ALL_CHARS.length; i++) {
    var c = String(list[i])
    if (PATTERNS[c] && !seen[c]) { seen[c] = true; out.push(c) }
  }
  return out
}

function parseState(raw) {
  var s = DEFAULT_STATE
  try {
    var parsed = JSON.parse(String(raw || ""))
    if (parsed && typeof parsed === "object") s = parsed
  } catch (e) { /* corrupt state falls back to defaults */ }
  return {
    wpm: clampInt(s.wpm, MIN_WPM, MAX_WPM, DEFAULT_STATE.wpm),
    delayMs: clampInt(s.delayMs, 0, MAX_DELAY, DEFAULT_STATE.delayMs),
    toneHz: clampInt(s.toneHz, MIN_TONE, MAX_TONE, DEFAULT_STATE.toneHz),
    volume: clampInt(s.volume, MIN_VOLUME, MAX_VOLUME, DEFAULT_STATE.volume),
    wordGaps: s.wordGaps !== false,
    chars: sanitizeChars(s.chars)
  }
}

function serializeState(s) {
  return JSON.stringify({
    wpm: clampInt(s.wpm, MIN_WPM, MAX_WPM, DEFAULT_STATE.wpm),
    delayMs: clampInt(s.delayMs, 0, MAX_DELAY, DEFAULT_STATE.delayMs),
    toneHz: clampInt(s.toneHz, MIN_TONE, MAX_TONE, DEFAULT_STATE.toneHz),
    volume: clampInt(s.volume, MIN_VOLUME, MAX_VOLUME, DEFAULT_STATE.volume),
    wordGaps: s.wordGaps === true,
    chars: sanitizeChars(s.chars)
  })
}

// ---- display helpers ----

function delayLabel(ms) {
  return (ms / 1000).toFixed(1) + " s"
}

// Strip characters that could smuggle rich-text markup into Text elements.
function plainText(value) {
  return String(value === null || value === undefined ? "" : value).replace(/[<>&]/g, "")
}

// Convert a resolved file:// URL to a filesystem path.
function assetPath(url) {
  var s = String(url || "")
  if (s.indexOf("file://") === 0) s = s.slice(7)
  try { return decodeURIComponent(s) } catch (e) { return s }
}
