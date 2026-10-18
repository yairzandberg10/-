#!/usr/bin/env python3
"""
make_audio.py - synthesises all Tel Batata music and sound effects from code
(no samples, no licences) and writes small mono OGG files to assets/audio/.

    python3 tools/make_audio.py          # needs numpy + ffmpeg (libvorbis)

Deterministic: running it again produces the same sounds.
"""
import os
import subprocess
import tempfile
import wave

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "assets", "audio")
SR = 32000
rng = np.random.default_rng(7)

NOTE = {"C": 0, "C#": 1, "D": 2, "D#": 3, "E": 4, "F": 5, "F#": 6, "G": 7, "G#": 8, "A": 9, "A#": 10, "B": 11}


def hz(name):
    """'A4' -> 440.0"""
    n, octave = name[:-1], int(name[-1])
    return 440.0 * 2 ** ((NOTE[n] + 12 * (octave - 4) - 9) / 12)


def t(sec):
    return np.arange(int(sec * SR)) / SR


def env(n, a=0.01, d=0.1, s=0.6, r=0.1):
    """ADSR envelope of n samples."""
    a_n, d_n, r_n = int(a * SR), int(d * SR), int(r * SR)
    s_n = max(n - a_n - d_n - r_n, 0)
    e = np.concatenate([np.linspace(0, 1, a_n, False), np.linspace(1, s, d_n, False),
                        np.full(s_n, s), np.linspace(s, 0, r_n)])
    return np.pad(e, (0, max(n - len(e), 0)))[:n]


def osc(kind, f, sec, duty=0.5):
    x = t(sec)
    ph = (f * x) % 1.0
    if kind == "sine":
        return np.sin(2 * np.pi * ph)
    if kind == "square":
        return np.where(ph < duty, 1.0, -1.0) * 0.6
    if kind == "tri":
        return 2 * np.abs(2 * ph - 1) - 1
    if kind == "saw":
        return (2 * ph - 1) * 0.6
    raise ValueError(kind)


def lowpass(x, cutoff):
    a = np.exp(-2 * np.pi * cutoff / SR)
    y = np.empty_like(x)
    acc = 0.0
    for i, v in enumerate(x):
        acc = (1 - a) * v + a * acc
        y[i] = acc
    return y


def lowpass_fast(x, cutoff, passes=2):
    # moving-average approximation, fine for pads/noise and much faster than the loop
    w = max(int(SR / cutoff / 2), 1)
    k = np.ones(w) / w
    for _ in range(passes):
        x = np.convolve(x, k, mode="same")
    return x


def noise(sec):
    return rng.uniform(-1, 1, int(sec * SR))


def place(buf, sig, at):
    i = int(at * SR)
    if i >= len(buf):
        return
    n = min(len(sig), len(buf) - i)
    buf[i:i + n] += sig[:n]


def place_wrap(buf, sig, at):
    """Like place() but wraps the tail to the start (seamless loops)."""
    i = int(at * SR) % len(buf)
    for k in range(0, len(sig), len(buf)):
        part = sig[k:k + len(buf)]
        end = i + len(part)
        if end <= len(buf):
            buf[i:end] += part
        else:
            cut = len(buf) - i
            buf[i:] += part[:cut]
            buf[:end - len(buf)] += part[cut:]


# ------------------------------------------------------------------ instruments

def lead(f, sec, vol=0.22, duty=0.25):
    # soft pulse lead: filtered square + triangle body, so it is cheerful but not harsh
    x = lowpass_fast(osc("square", f, sec, duty), 2600, 1) + 0.6 * osc("tri", f, sec)
    return x * env(len(x), 0.008, 0.08, 0.55, min(0.08, sec / 3)) * vol


def bell(f, sec, vol=0.18):
    x = osc("sine", f, sec) + 0.35 * osc("sine", f * 2.01, sec) + 0.1 * osc("sine", f * 3.99, sec)
    return x * np.exp(-t(sec) * 5) * vol


def bass(f, sec, vol=0.32):
    x = osc("tri", f, sec) + 0.25 * osc("square", f, sec, 0.5)
    return x * env(len(x), 0.005, 0.05, 0.7, 0.04) * vol


def pad(freqs, sec, vol=0.07):
    x = sum(osc("saw", f, sec) + osc("saw", f * 1.003, sec) for f in freqs)
    x = lowpass_fast(x, 1400)
    return x * env(len(x), 0.15, 0.2, 0.8, 0.25) * vol


def kick(vol=0.6):
    s = t(0.25)
    f = 120 * np.exp(-s * 18) + 45
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-s * 12) * vol


def snare(vol=0.28):
    s = t(0.18)
    n = lowpass_fast(noise(0.18), 6000, 1) * np.exp(-s * 22)
    tone = np.sin(2 * np.pi * 190 * s) * np.exp(-s * 30) * 0.4
    return (n + tone) * vol


def hat(vol=0.05, length=0.04):
    n = noise(length)
    n = n - lowpass_fast(n, 3000, 1)
    return n * np.exp(-t(length) * 70) * vol


# ------------------------------------------------------------------ songs

CHORDS = {
    "C": ["C3", "E3", "G3"], "G": ["G2", "B2", "D3"], "Am": ["A2", "C3", "E3"], "F": ["F2", "A2", "C3"],
    "Dm": ["D3", "F3", "A3"], "Em": ["E3", "G3", "B3"], "E": ["E3", "G#3", "B3"],
}


def song(bpm, bars, chords, melody, drums="pop", swing=0.0, lead_duty=0.25, bass_pattern="pulse"):
    beat = 60.0 / bpm
    length = bars * 4 * beat
    buf = np.zeros(int(length * SR))
    for b in range(bars):
        t0 = b * 4 * beat
        ch = chords[b % len(chords)]
        notes = [hz(n) for n in CHORDS[ch]]
        place_wrap(buf, pad([f * 2 for f in notes], 4 * beat), t0)
        root = notes[0] / 2 if notes[0] > 90 else notes[0]
        if bass_pattern == "pulse":
            for k, mult in enumerate([1, 1, 2, 1, 1, 1, 1.5, 2]):
                place_wrap(buf, bass(root * mult, beat * 0.45), t0 + k * beat / 2)
        else:  # walking
            for k, mult in enumerate([1, 1.5, 2, 1.5]):
                place_wrap(buf, bass(root * mult, beat * 0.9), t0 + k * beat)
        for k in range(8):
            sw = swing * beat / 2 if k % 2 else 0
            if drums == "pop":
                if k in (0, 4):
                    place_wrap(buf, kick(), t0 + k * beat / 2)
                if k in (2, 6):
                    place_wrap(buf, snare(), t0 + k * beat / 2)
                place_wrap(buf, hat(0.035 if k % 2 else 0.055), t0 + k * beat / 2 + sw)
            elif drums == "drive":
                if k % 2 == 0:
                    place_wrap(buf, kick(0.55), t0 + k * beat / 2)
                if k in (2, 6):
                    place_wrap(buf, snare(0.32), t0 + k * beat / 2)
                place_wrap(buf, hat(0.055), t0 + k * beat / 2 + sw)
                place_wrap(buf, hat(0.03, 0.03), t0 + k * beat / 2 + beat / 4)
    # melody: list of (bar, beat_offset, note_or_None, beats)
    for (bar, off, n, dur) in melody:
        if n is None:
            continue
        sw = swing * beat / 2 if (off * 2) % 2 == 1 else 0
        place_wrap(buf, lead(hz(n), dur * beat * 0.95, duty=lead_duty), bar * 4 * beat + off * beat + sw)
        place_wrap(buf, bell(hz(n) * 2, dur * beat, 0.05), bar * 4 * beat + off * beat + sw)
    return buf


def phrase(bar0, spec):
    """spec: list of bars, each a list of (note, beats). Returns melody events."""
    ev = []
    for i, bar in enumerate(spec):
        pos = 0.0
        for n, d in bar:
            ev.append((bar0 + i, pos, n, d))
            pos += d
    return ev


def city_theme():
    a = [
        [("E5", 1), ("G5", 0.5), ("E5", 0.5), ("C5", 1), ("D5", 1)],
        [("D5", 0.5), ("E5", 0.5), ("D5", 0.5), ("B4", 0.5), ("G4", 2)],
        [("A4", 0.5), ("C5", 0.5), ("E5", 1), ("D5", 0.5), ("C5", 0.5), ("A4", 1)],
        [("F4", 0.5), ("A4", 0.5), ("C5", 1), ("D5", 0.5), ("C5", 0.5), ("A4", 1)],
        [("E5", 1), ("G5", 0.5), ("A5", 0.5), ("G5", 1), ("E5", 1)],
        [("D5", 0.5), ("E5", 0.5), ("G5", 1), ("D5", 2)],
        [("C5", 0.5), ("D5", 0.5), ("E5", 0.5), ("C5", 0.5), ("A4", 1), ("C5", 1)],
        [("F4", 0.5), ("G4", 0.5), ("A4", 0.5), ("D5", 0.5), ("C5", 2)],
    ]
    b = [
        [("A5", 1.5), ("G5", 0.5), ("E5", 1), ("C5", 1)],
        [("D5", 1.5), ("E5", 0.5), ("D5", 1), ("B4", 1)],
        [("C5", 0.5), ("E5", 0.5), ("A5", 1), ("G5", 0.5), ("E5", 0.5), ("C5", 1)],
        [("F5", 1), ("E5", 0.5), ("D5", 0.5), ("C5", 1), ("A4", 1)],
        [("G5", 0.5), ("A5", 0.5), ("G5", 0.5), ("E5", 0.5), ("C5", 1), ("E5", 1)],
        [("D5", 1), ("B4", 0.5), ("D5", 0.5), ("G5", 2)],
        [("A5", 0.5), ("G5", 0.5), ("E5", 0.5), ("C5", 0.5), ("D5", 1), ("E5", 1)],
        [("D5", 1), ("G4", 1), ("C5", 2)],
    ]
    mel = phrase(0, a) + phrase(8, b) + phrase(16, a) + phrase(24, b)
    return song(112, 32, ["C", "G", "Am", "F"], mel, "pop", swing=0.18)


def fight_theme():
    a = [
        [("A4", 0.5), ("A4", 0.5), ("C5", 0.5), ("A4", 0.5), ("E5", 1), ("D5", 1)],
        [("C5", 0.5), ("A4", 0.5), ("F4", 1), ("A4", 0.5), ("C5", 0.5), ("F5", 1)],
        [("E5", 0.5), ("D5", 0.5), ("C5", 0.5), ("G4", 0.5), ("C5", 1), ("E5", 1)],
        [("D5", 0.5), ("B4", 0.5), ("G4", 1), ("B4", 0.5), ("D5", 0.5), ("G5", 1)],
    ]
    b = [
        [("A5", 1), ("G5", 0.5), ("E5", 0.5), ("C5", 1), ("E5", 1)],
        [("F5", 1), ("E5", 0.5), ("C5", 0.5), ("A4", 2)],
        [("G5", 0.5), ("E5", 0.5), ("G5", 0.5), ("C6", 0.5), ("G5", 1), ("E5", 1)],
        [("D5", 0.5), ("E5", 0.5), ("G5", 1), ("B5", 1), ("E5", 1)],
    ]
    mel = phrase(0, a) + phrase(4, b) + phrase(8, a) + phrase(12, b)
    return song(140, 16, ["Am", "F", "C", "G"], mel, "drive", lead_duty=0.5)


def victory():
    buf = np.zeros(int(2.6 * SR))
    for i, n in enumerate(["C5", "E5", "G5", "C6"]):
        place(buf, lead(hz(n), 0.18, 0.25), i * 0.12)
        place(buf, bell(hz(n) * 2, 0.4, 0.08), i * 0.12)
    for n in ["C5", "E5", "G5", "C6"]:
        place(buf, lead(hz(n), 1.6, 0.12, 0.5), 0.55)
        place(buf, bell(hz(n), 2.0, 0.08), 0.55)
    place(buf, kick(), 0.55)
    place(buf, pad([hz("C4"), hz("E4"), hz("G4")], 1.9, 0.1), 0.55)
    return buf


def ocean():
    """Seamless 8s wave loop: low-passed noise with slow swells."""
    sec = 8.0
    n = lowpass_fast(noise(sec), 500, 3)
    swell = 0.55 + 0.45 * np.sin(2 * np.pi * t(sec) / 4.0 - np.pi / 2) ** 2
    x = n * swell
    fade = int(0.5 * SR)
    x[:fade] = x[:fade] * np.linspace(0, 1, fade) + x[-fade:] * np.linspace(1, 0, fade)
    x = x[:-fade]
    return x / np.max(np.abs(x)) * 0.5


# ------------------------------------------------------------------ effects

def sweep(f0, f1, sec, kind="square", curve=1.0):
    s = t(sec)
    f = f0 + (f1 - f0) * (s / sec) ** curve
    ph = np.cumsum(f) / SR % 1.0
    if kind == "square":
        return np.where(ph < 0.5, 1.0, -1.0) * 0.5
    if kind == "sine":
        return np.sin(2 * np.pi * ph)
    return 2 * np.abs(2 * ph - 1) - 1


def sfx():
    out = {}
    out["jump"] = sweep(260, 620, 0.16, "square", 0.6) * env(int(0.16 * SR), 0.005, 0.05, 0.6, 0.08) * 0.35
    c = np.zeros(int(0.35 * SR))
    place(c, bell(hz("B5"), 0.1, 0.5), 0)
    place(c, bell(hz("E6"), 0.3, 0.5), 0.07)
    out["coin"] = c
    s = t(0.3)
    plop = sweep(520, 90, 0.3, "sine", 0.5) * np.exp(-s * 9) * 0.7
    plop += lowpass_fast(noise(0.3), 2500, 1) * np.exp(-s * 25) * 0.4
    out["plop"] = plop
    s = t(0.22)
    out["swing"] = (lowpass_fast(noise(0.22), 1800, 1) * np.sin(np.pi * s / 0.22) ** 2) * 0.6
    s = t(0.35)
    out["hurt"] = sweep(500, 180, 0.35, "square", 1.0) * (0.6 + 0.4 * np.sin(2 * np.pi * 18 * s)) * np.exp(-s * 5) * 0.35
    d = np.zeros(int(0.5 * SR))
    for k in range(2):
        s2 = t(0.12)
        place(d, (np.sin(2 * np.pi * 140 * s2) + lowpass_fast(noise(0.12), 1500, 1) * 0.6) * np.exp(-s2 * 35) * 0.6, k * 0.16)
    out["door"] = d
    out["blip"] = osc("square", 880, 0.05, 0.5) * env(int(0.05 * SR), 0.002, 0.02, 0.5, 0.02) * 0.18
    out["click"] = osc("sine", 1200, 0.04) * np.exp(-t(0.04) * 90) * 0.4
    o = np.zeros(int(0.25 * SR))
    place(o, bell(hz("G5"), 0.1, 0.35), 0)
    place(o, bell(hz("C6"), 0.2, 0.35), 0.06)
    out["ui_open"] = o
    q = np.zeros(int(1.1 * SR))
    for i, n in enumerate(["G5", "C6", "E6", "G6"]):
        place(q, bell(hz(n), 0.6, 0.3), i * 0.09)
        place(q, lead(hz(n), 0.12, 0.1, 0.5), i * 0.09)
    out["quest"] = q
    h = np.zeros(int(0.7 * SR))
    for f in (hz("F4"), hz("A4")):
        place(h, osc("square", f, 0.6, 0.5) * env(int(0.6 * SR), 0.01, 0.05, 0.8, 0.08) * 0.22, 0)
    out["horn"] = h
    s = t(1.0)  # engine loop: periodic, 1 second exactly so it loops seamlessly
    f = 55.0
    eng = osc("saw", f, 1.0) + 0.6 * osc("square", f * 2, 1.0, 0.3) + 0.3 * osc("saw", f * 3, 1.0)
    eng = lowpass_fast(eng, 900, 1) * (0.8 + 0.2 * np.sin(2 * np.pi * 11 * s))
    out["engine"] = eng / np.max(np.abs(eng)) * 0.45
    s = t(0.06)
    out["step"] = lowpass_fast(noise(0.06), 900, 1) * np.exp(-s * 70) * 0.5
    sp = np.zeros(int(0.5 * SR))
    for i, n in enumerate(["E6", "G6", "B6", "E7"]):
        place(sp, bell(hz(n), 0.25, 0.22), i * 0.05)
    out["pickup"] = sp
    s = t(0.5)
    out["splash"] = lowpass_fast(noise(0.5), 3500, 1) * np.exp(-s * 8) * 0.5
    s = t(0.4)
    out["skid"] = (lowpass_fast(noise(0.4), 2500, 1) * 0.5 + osc("square", 700, 0.4, 0.5) * 0.08) * env(int(0.4 * SR), 0.02, 0.1, 0.7, 0.1)
    s = t(0.3)
    out["bump"] = (np.sin(2 * np.pi * 80 * s) + lowpass_fast(noise(0.3), 800, 1)) * np.exp(-s * 14) * 0.6
    return out


# ------------------------------------------------------------------ output

def write_ogg(name, x, quality=3):
    x = np.clip(x / max(np.max(np.abs(x)), 1e-9) * 0.89, -1, 1)
    pcm = (x * 32767).astype(np.int16)
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        tmp = f.name
    with wave.open(tmp, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    dst = os.path.join(OUT, name + ".ogg")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", tmp, "-c:a", "libvorbis", "-q:a", str(quality), dst], check=True)
    os.remove(tmp)
    print(f"{name}.ogg  {len(x) / SR:5.1f}s  {os.path.getsize(dst) // 1024} KB")


def main():
    os.makedirs(OUT, exist_ok=True)
    write_ogg("music_city", city_theme())
    write_ogg("music_fight", fight_theme())
    write_ogg("music_victory", victory())
    write_ogg("amb_ocean", ocean(), 1)
    for k, v in sfx().items():
        write_ogg("sfx_" + k, v, 2)


if __name__ == "__main__":
    main()
