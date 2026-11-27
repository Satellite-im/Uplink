#!/usr/bin/env python3
"""The Soundboard plugin's own sounds (lib/voice/soundboard.dart), made here from sums and noise alone, so they are the
app's to give away with its source: nothing recorded, nothing from a library of sounds.

  python3 tool/soundboard_sounds.py        writes assets/soundboard/<id>.wav (mono, 16-bit, 22050 Hz)

The same every run (the noise is seeded). Change a sound here and run it again; the ids are what is said in a call, so
keep them.
"""
import math, os, random, struct, wave

# The sample rate every sound is made and written at. A sound is a list of floats, one a sample.
R = 22050
TAU = 2 * math.pi


# How loud sample i of n is: a straight rise over `attack` seconds from the start, a straight fall over `release` to
# the end, 0..1.
def env(i, n, attack=0.01, release=0.05):
    t, end = i / R, n / R
    a = min(1.0, t / attack) if attack > 0 else 1.0
    r = min(1.0, (end - t) / release) if release > 0 else 1.0
    return max(0.0, min(a, r))


# A pitched note: a sine, square or saw wave, or with `harmonics` a sum of sines, each (multiple of freq, loudness).
# `vibrato` is how far the pitch wavers each way, as a part of it, 5.5 times a second.
def tone(freq, secs, shape="sine", vol=1.0, attack=0.01, release=0.05, vibrato=0.0, harmonics=None):
    """freq: a number, or a function of time in seconds."""
    n = int(secs * R)
    out, phase = [], 0.0
    for i in range(n):
        t = i / R
        f = freq(t) if callable(freq) else freq
        if vibrato:
            f *= 1 + vibrato * math.sin(TAU * 5.5 * t)
        phase += TAU * f / R
        if harmonics:
            s = sum(a * math.sin(k * phase) for k, a in harmonics)
        elif shape == "square":
            s = 1.0 if math.sin(phase) >= 0 else -1.0
        elif shape == "saw":
            s = (phase / math.pi) % 2 - 1
        else:
            s = math.sin(phase)
        out.append(s * vol * env(i, n, attack, release))
    return out


def noise(secs, rng, vol=1.0, low=0.0, high=0.0, attack=0.005, release=0.05, decay=0.0):
    """White noise; low: one-pole low-pass amount (0..1), high: the same taken away (a high-pass); decay: e^(-t/decay)."""
    n = int(secs * R)
    out, lp, hp = [], 0.0, 0.0
    for i in range(n):
        s = rng.uniform(-1, 1)
        if low:
            lp += (1 - low) * (s - lp)
            s = lp
        if high:
            hp += (1 - high) * (s - hp)
            s = s - hp
        e = env(i, n, attack, release)
        if decay:
            e *= math.exp(-(i / R) / decay)
        out.append(s * vol * e)
    return out


def silence(secs):
    return [0.0] * int(secs * R)


# Sounds played together: added sample by sample, as long as the longest.
def mix(*parts):
    n = max(len(p) for p in parts)
    return [sum(p[i] for p in parts if i < len(p)) for i in range(n)]


# `part`, starting `secs` in: for placing a sound inside a mix.
def at(secs, part):
    return silence(secs) + part


# The instruments the sounds below are built from. A bell: a note and overtones that are not whole multiples of it,
# dying away from the strike.
def bell(freq, secs, vol=1.0):
    n = int(secs * R)
    return [vol * math.exp(-(i / R) * 4.5 / secs * 1.6) * (math.sin(TAU * freq * i / R) + 0.45 * math.sin(TAU * freq * 2.76 * i / R) + 0.2 * math.sin(TAU * freq * 5.4 * i / R)) * min(1, i / 40) for i in range(n)]


def brass(freq, secs, vol=1.0, vibrato=0.0):
    return tone(freq, secs, vol=vol, attack=0.03, release=0.08, vibrato=vibrato, harmonics=[(1, 1.0), (2, 0.6), (3, 0.45), (4, 0.3), (5, 0.2), (6, 0.12), (7, 0.08)])


# A drum hit: a short sine whose pitch drops as it dies, with a snap of high noise on top.
def drum(freq, secs, rng, vol=1.0):
    n = int(secs * R)
    body = [vol * math.exp(-(i / R) * 22) * math.sin(TAU * (freq + 60 * math.exp(-(i / R) * 40)) * i / R) for i in range(n)]
    return mix(body, noise(secs, rng, vol=vol * 0.5, high=0.6, decay=0.035))


def cymbal(secs, rng, vol=1.0):
    return noise(secs, rng, vol=vol, high=0.25, attack=0.001, release=0.1, decay=secs / 4)


# The sounds themselves, one function each. Every one takes the seeded generator its noise comes from, whether it
# uses any or not, so SOUNDS can call them all alike.
def airhorn(rng):
    def blast(secs):
        return mix(*[tone(f, secs, shape="saw", vol=0.3, attack=0.02, release=0.06, vibrato=0.004) for f in (415, 440, 523, 622)])
    return blast(0.22) + silence(0.07) + blast(0.22) + silence(0.07) + blast(1.1)


def applause(rng):
    secs = 2.8
    n = int(secs * R)
    out = [0.0] * n
    # Many hands: short bursts of filtered noise, thick in the middle and thinning out.
    for _ in range(520):
        start = rng.betavariate(1.3, 2.2) * (secs - 0.05)
        clap = noise(rng.uniform(0.012, 0.03), rng, vol=rng.uniform(0.25, 0.7), low=rng.uniform(0.2, 0.55), high=0.5, attack=0.001, release=0.01)
        s = int(start * R)
        for i, v in enumerate(clap):
            if s + i < n:
                out[s + i] += v
    return [v * env(i, n, 0.15, 0.9) for i, v in enumerate(out)]


def rimshot(rng):
    return mix(drum(140, 0.22, rng, 0.9), at(0.2, drum(110, 0.25, rng, 0.9)), at(0.52, mix(cymbal(0.9, rng, 0.7), drum(200, 0.1, rng, 0.5))))


def trombone(rng):
    def slide(f0, f1, secs):
        return brass(lambda t: f0 + (f1 - f0) * (t / secs) ** 1.5, secs, vol=0.33, vibrato=0.012)
    return slide(294, 277, 0.42) + silence(0.04) + slide(277, 262, 0.42) + silence(0.04) + slide(262, 247, 0.42) + silence(0.04) + slide(247, 196, 1.2)


def ding(rng):
    return mix(bell(1318.5, 1.6, 0.6), bell(1975.5, 1.2, 0.2))


def buzzer(rng):
    return mix(tone(120, 0.9, shape="square", vol=0.35, attack=0.005, release=0.03), tone(126, 0.9, shape="saw", vol=0.3, attack=0.005, release=0.03))


def crickets(rng):
    out = silence(2.6)
    for start in (0.1, 0.75, 1.4, 2.05):
        for k in range(3):
            chirp = [0.5 * math.sin(TAU * 4300 * i / R) * (0.5 + 0.5 * math.sin(TAU * 62 * i / R)) * env(i, int(0.085 * R), 0.01, 0.02) for i in range(int(0.085 * R))]
            s = int((start + k * 0.11) * R)
            for i, v in enumerate(chirp):
                if s + i < len(out):
                    out[s + i] += v
    return mix(out, noise(2.6, rng, vol=0.015, low=0.3, attack=0.2, release=0.3))


def drumroll(rng):
    secs = 2.0
    out = silence(secs + 0.9)
    t, gap = 0.0, 0.07
    while t < secs:
        hit = drum(190, 0.06, rng, 0.25 + 0.5 * (t / secs))
        s = int(t * R)
        for i, v in enumerate(hit):
            out[s + i] += v
        # The hits come closer together and louder as the roll goes on, then the crash.
        gap = max(0.028, gap * 0.97)
        t += gap
    crash = mix(cymbal(0.9, rng, 0.8), drum(120, 0.25, rng, 0.9))
    s = int(secs * R)
    for i, v in enumerate(crash):
        if s + i < len(out):
            out[s + i] += v
    return out


def tada(rng):
    def chord(notes, secs, vol):
        return mix(*[brass(f, secs, vol=vol, vibrato=0.006) for f in notes])
    return chord((392, 494, 587), 0.16, 0.16) + silence(0.03) + mix(chord((523, 659, 784, 1047), 1.3, 0.14), cymbal(1.2, rng, 0.25))


def boing(rng):
    secs = 0.9
    n = int(secs * R)
    out, phase = [], 0.0
    for i in range(n):
        t = i / R
        # A spring: the pitch falls towards 180 Hz and wobbles 13 times a second on the way down.
        f = 180 + 260 * math.exp(-t * 3) * (1 + 0.5 * math.sin(TAU * 13 * t))
        phase += TAU * f / R
        out.append(0.7 * math.exp(-t * 3.2) * (math.sin(phase) + 0.3 * math.sin(2 * phase)) * min(1, i / 60))
    return out


def pew(rng):
    def shot():
        return tone(lambda t: 2200 * math.exp(-t * 9) + 180, 0.28, shape="saw", vol=0.45, attack=0.002, release=0.08)
    return shot() + silence(0.05) + shot() + silence(0.05) + shot()


def whoosh(rng):
    secs = 1.1
    n = int(secs * R)
    out, lp = [], 0.0
    for i in range(n):
        x = i / n
        k = 0.97 - 0.75 * math.sin(math.pi * x)  # the filter opens and closes
        lp += (1 - k) * (rng.uniform(-1, 1) - lp)
        out.append(lp * 1.6 * math.sin(math.pi * x) ** 2)
    return out


# Sounds that are dense all the way through are written lower, so every pad is about as loud as the next.
PEAKS = {"buzzer": 0.45, "pew": 0.55, "trombone": 0.6, "airhorn": 0.8}

SOUNDS = [("airhorn", airhorn), ("applause", applause), ("rimshot", rimshot), ("trombone", trombone), ("ding", ding), ("buzzer", buzzer), ("crickets", crickets), ("drumroll", drumroll), ("tada", tada), ("boing", boing), ("pew", pew), ("whoosh", whoosh)]


# Writes a sound as a mono 16-bit WAV, scaled so its loudest sample is at `peak` of full scale.
def write(path, samples, peak=0.85):
    top = max(1e-9, max(abs(s) for s in samples))
    scale = peak / top
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(R)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s * scale)) * 32767)) for s in samples))


if __name__ == "__main__":
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "soundboard")
    os.makedirs(out, exist_ok=True)
    for i, (name, make) in enumerate(SOUNDS):
        # A generator of its own for each sound, seeded by its place in the list: changing one leaves the rest alone.
        samples = make(random.Random(1000 + i))
        write(os.path.join(out, name + ".wav"), samples, PEAKS.get(name, 0.85))
        print(f"ok {name}.wav {len(samples) / R:.2f}s")
