#!/usr/bin/env python3
"""CW (Morse) sidetone player for the Omarchy CW Practice plugin.

Runs as a long-lived child of the shell. Sends random characters from the
selected pool with proper PARIS timing into a `pacat --raw` stream, and
prints each character to stdout as its audio finishes playing, so the shell
can reveal it into the history after the configured delay.

stdout protocol: one line per sent character. A trailing space in the line
means a word gap (7-dit pause) follows that character.

stdin protocol (live settings, applied at the next character boundary):
  SET wpm=<int>
  SET tone=<int>
  SET volume=<int>
  SET pool=<chars, no separator>
  SET word-gaps=<0|1>
EOF on stdin (parent gone) ends the session.

The Morse table MUST stay in sync with PATTERNS in Model.js.
"""

import argparse
import math
import os
import random
import signal
import subprocess
import sys
import threading
import time
from array import array

RATE = 44100
MORSE = {
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
    "$": "...-..-",
}
LEADING_SILENCE = 0.3
RAMP_SECS = 0.005


def tone_block(seconds, freq, amp):
    """Sine keyed block with short cosine-ish ramps to avoid key clicks."""
    n = max(1, int(round(seconds * RATE)))
    ramp = min(n // 8, max(1, int(round(RAMP_SECS * RATE))))
    buf = array("h")
    two_pi_f = 2.0 * math.pi * freq
    for i in range(n):
        g = 1.0
        if i < ramp:
            g = i / ramp
        elif i >= n - ramp:
            g = (n - 1 - i) / ramp
        buf.append(int(amp * g * math.sin(two_pi_f * i / RATE)))
    return buf.tobytes()


def silence_block(seconds):
    return b"\x00\x00" * max(1, int(round(seconds * RATE)))


def fail(msg):
    sys.stderr.write("audio error: %s\n" % msg)
    sys.stderr.flush()
    sys.exit(1)


class Config:
    """Live settings, updated from the stdin reader thread."""

    def __init__(self, wpm, tone, volume, pool, word_gaps):
        self.lock = threading.Lock()
        self.wpm = wpm
        self.tone = tone
        self.volume = volume
        self.pool = list(pool)
        self.word_gaps = word_gaps

    def snapshot(self):
        with self.lock:
            return (self.wpm, self.tone, self.volume,
                    list(self.pool), self.word_gaps)

    def apply(self, line):
        """Apply one 'SET key=value' line. Returns an error string or None."""
        t = line.strip()
        if not t:
            return None
        if not t.startswith("SET "):
            return "bad command: %s" % t
        key, _, value = t[4:].partition("=")
        key = key.strip()
        value = value.strip()
        if key == "wpm":
            n = int(value)
            if not 5 <= n <= 60:
                return "wpm out of range"
            with self.lock:
                self.wpm = n
        elif key == "tone":
            n = int(value)
            if not 100 <= n <= 1500:
                return "tone out of range"
            with self.lock:
                self.tone = n
        elif key == "volume":
            n = int(value)
            if not 0 <= n <= 100:
                return "volume out of range"
            with self.lock:
                self.volume = n
        elif key == "pool":
            pool = [c for c in value if c in MORSE]
            if not pool:
                return "no valid characters selected"
            with self.lock:
                self.pool = pool
        elif key == "word-gaps":
            with self.lock:
                self.word_gaps = value == "1"
        else:
            return "unknown key: %s" % key
        return None


class Blocks:
    """Cached element blocks for the current wpm/tone/volume. Rebuilt when
    any of those change, so a live settings change costs one rebuild at the
    next character boundary instead of a stream restart."""

    def __init__(self):
        self.key = None
        self.dit_tone = b""
        self.dah_tone = b""
        self.gap1 = b""
        self.gap3 = b""
        self.gap7 = b""
        self.leading = b""

    def ensure(self, wpm, tone, volume):
        key = (wpm, tone, volume)
        if key == self.key:
            return
        dit = 1.2 / wpm  # PARIS: dit = 1.2 / WPM seconds
        amp = int(32767 * 0.9 * (volume / 100.0))
        self.dit_tone = tone_block(dit, tone, amp)
        self.dah_tone = tone_block(3 * dit, tone, amp)
        self.gap1 = silence_block(dit)
        self.gap3 = silence_block(3 * dit)
        self.gap7 = silence_block(7 * dit)
        self.leading = silence_block(LEADING_SILENCE)
        self.key = key


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wpm", type=float, required=True)
    ap.add_argument("--tone", type=float, default=600.0)
    ap.add_argument("--volume", type=int, default=70)
    ap.add_argument("--pool", required=True)
    ap.add_argument("--word-gaps", action="store_true")
    args = ap.parse_args()

    pool = [c for c in args.pool if c in MORSE]
    if not pool:
        fail("no valid characters selected")

    cfg = Config(min(max(args.wpm, 5.0), 60.0),
                 min(max(args.tone, 100.0), 1500.0),
                 min(max(args.volume, 0), 100),
                 pool, args.word_gaps)
    blocks = Blocks()

    try:
        sink = subprocess.Popen(
            ["pacat", "--raw", "--volume=65536",
             "--rate=%d" % RATE, "--format=s16le",
             "--channels=1", "--latency-msec=100"],
            stdin=subprocess.PIPE)
    except OSError as e:
        fail("cannot start pacat: %s" % e)

    def shutdown(signum, frame):
        try:
            sink.kill()
        except OSError:
            pass
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    # Live settings: read stdin line by line, apply at the next boundary.
    # A malformed line is reported and skipped — the reader must survive so
    # the EOF watchdog below keeps working. sys.exit() in a non-main thread
    # only ends the thread, so EOF signals the main thread instead.
    def reader():
        for line in sys.stdin:
            try:
                err = cfg.apply(line)
            except ValueError as e:
                err = "invalid value: %s" % e
            if err:
                sys.stderr.write("settings error: %s\n" % err)
                sys.stderr.flush()
        os.kill(os.getpid(), signal.SIGTERM)

    threading.Thread(target=reader, daemon=True).start()

    rng = random.Random()
    word_left = rng.randint(2, 5)

    # Pace printing (and therefore writing) against wall-clock playback time,
    # so pacat's buffering can't let us run ahead of the audio.
    t0 = time.monotonic()
    sent = 0.0

    def pace(target):
        while True:
            remaining = target - time.monotonic()
            if remaining <= 0:
                return
            time.sleep(min(remaining, 0.1))

    try:
        leading = True
        while True:
            wpm, tone, volume, pool, word_gaps = cfg.snapshot()
            blocks.ensure(wpm, tone, volume)
            dit = 1.2 / wpm

            ch = rng.choice(pool)
            pattern = MORSE[ch]
            boundary = word_gaps and word_left == 0
            parts = []
            had_leading = leading
            if had_leading:
                parts.append(blocks.leading)
                leading = False
            for i, el in enumerate(pattern):
                if i > 0:
                    parts.append(blocks.gap1)
                parts.append(blocks.dit_tone if el == "." else blocks.dah_tone)
            parts.append(blocks.gap7 if boundary else blocks.gap3)
            if boundary:
                word_left = rng.randint(2, 5)
            else:
                word_left -= 1

            # Full audio duration of what we're about to write, including
            # the leading silence on the first character — the print clock
            # must never run ahead of true playback.
            dur = LEADING_SILENCE if had_leading else 0.0

            try:
                sink.stdin.write(b"".join(parts))
                sink.stdin.flush()
            except (BrokenPipeError, OSError):
                fail("audio stream closed")
            if sink.poll() is not None:
                fail("audio stream closed")

            for i, el in enumerate(pattern):
                if i > 0:
                    dur += dit
                dur += dit if el == "." else 3 * dit

            dur += 7 * dit if boundary else 3 * dit
            sent += dur
            pace(t0 + sent)
            sys.stdout.write(ch + (" " if boundary else "") + "\n")
            sys.stdout.flush()
    finally:
        try:
            sink.kill()
        except OSError:
            pass




if __name__ == "__main__":
    main()
