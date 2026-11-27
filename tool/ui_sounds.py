#!/usr/bin/env python3
"""Uplink's interface sounds, made with ElevenLabs' sound effects (POST /v1/sound-generation), as Uplink
Keyboard's tool/sound_packs.py makes its packs, with the same key (Matt, 2026-11-16: "I want to have them generated via
the same way we generated other elevenlabs sounds using the same existing key", for the sounds of new friend
requests, messages in and out, connecting and disconnecting, mute and unmute, "they should all be cohesive").

Every prompt starts with the same words ([STYLE]) so the set sounds like one family, and pairs (mute and unmute, join
and leave, connected and disconnected) are written as mirror images. Each sound is asked for [TAKES] times; every take
is kept, trimmed of silence at both ends, as <event>-<n>.mp3 and a mono <event>-<n>.ogg (Opus, as assets/sounds/README.md has it), in
~/Desktop/Ghost Messaging sounds/ (or --out). prompts.json there says which words and model made each file.

The model is ElevenLabs' newest sound-effects model the account takes: the first of [MODELS] it accepts.
The key: $ELEVENLABS_API_KEY, else ~/.elevenlabs-key. Never an argument, never printed.

    python3 tool/ui_sounds.py              every sound not made yet
    python3 tool/ui_sounds.py --again      all of them again
    python3 tool/ui_sounds.py mute unmute  only these
"""
import json, os, pathlib, subprocess, sys, tempfile, urllib.error, urllib.request

OUT = pathlib.Path.home() / 'Desktop' / 'Ghost Messaging sounds'
TAKES = 3
MODELS = ['eleven_text_to_sound_v3', 'eleven_text_to_sound_v2']

STYLE = ('Minimal UI sound for a calm, monochrome messaging app called Ghost. Soft, airy and warm, like a felt-muted '
         'glass marimba with a faint breathy shimmer. Clean, close, dry, no reverb tail, no music, no voice, no '
         'background noise.')

# event: (seconds, what it is), the seconds being what ElevenLabs is asked for (it makes at least half a second).
SOUNDS = {
    # Messages
    'message-in': (0.6, 'Two soft rising notes, a gentle airy "ba-ding", friendly and quiet.'),
    'message-out': (0.5, 'A single quick soft upward whoosh ending in a tiny glassy tick, like a note floating away.'),
    'message-failed': (0.6, 'Two soft falling notes, slightly muted and low, a gentle "uh-oh", not alarming.'),
    'reaction': (0.5, 'One tiny bright glassy pop, light and playful.'),
    'code-copied': (0.5, 'A crisp soft click with a faint sparkle on top.'),
    # Friends and groups
    'friend-request': (0.9, 'Three soft ascending notes with a warm breathy shimmer, curious and inviting.'),
    'friend-accepted': (0.9, 'Three soft notes resolving upward into a warm major chord, a small happy flourish.'),
    'group-added': (0.8, 'A soft rising arpeggio of four quick notes, airy and welcoming.'),
    # Hangouts and calls
    'hangout-join': (0.7, 'A soft rising swell opening into a single clear glassy note, like a door gently opening.'),
    'hangout-leave': (0.7, 'A single clear glassy note falling softly into a muted swell, like a door gently closing.'),
    'someone-joined': (0.5, 'One soft bright upward blip, short and airy.'),
    'someone-left': (0.5, 'One soft low downward blip, short and airy.'),
    'ring-in': (2.5, 'A gentle repeating two-note glassy chime with a breathy shimmer, calm and loopable, even rhythm.'),
    'ring-out': (2.5, 'A soft low pulsing tone, two quiet pulses then a pause, calm and loopable.'),
    'call-ended': (0.6, 'Two soft descending notes settling to silence, final and calm.'),
    # Mute
    'mute': (0.5, 'A soft muffled downward click, like a felt pad closing.'),
    'unmute': (0.5, 'A soft clear upward click, like a felt pad opening, slightly brighter.'),
    'deafen': (0.5, 'A low soft muffled thud with the shimmer cut off.'),
    'undeafen': (0.5, 'A soft clear rising tone with the shimmer returning.'),
    # Connection
    'connected': (0.8, 'Two soft notes meeting in a gentle harmony, a quiet "linked" feeling, warm and reassuring.'),
    'disconnected': (0.8, 'Two soft notes drifting apart and fading downward, a quiet "unlinked" feeling, not alarming.'),
    'reconnecting': (1.2, 'A soft breathy pulse rising and falling twice, patient and calm.'),
}

# Loops keep their length; the rest have their silence cut.
LOOPS = {'ring-in', 'ring-out'}


# The ElevenLabs key, from the environment or ~/.elevenlabs-key; stops with why where there is none.
def key() -> str:
    k = os.environ.get('ELEVENLABS_API_KEY', '').strip()
    if not k:
        f = pathlib.Path.home() / '.elevenlabs-key'
        k = f.read_text().strip() if f.exists() else ''
    if not k:
        sys.exit('No ElevenLabs key: set ELEVENLABS_API_KEY or put it in ~/.elevenlabs-key.')
    return k


# One take of a sound from ElevenLabs' sound generation, as MP3 bytes: `text` says it, `seconds` (half a second at
# least) is how long it runs.
def generate(api_key: str, model: str, text: str, seconds: float) -> bytes:
    body = json.dumps({'text': text, 'duration_seconds': max(0.5, seconds), 'prompt_influence': 0.7, 'model_id': model}).encode()
    req = urllib.request.Request('https://api.elevenlabs.io/v1/sound-generation?output_format=mp3_44100_128', data=body,
                                 headers={'xi-api-key': api_key, 'Content-Type': 'application/json', 'Accept': 'audio/mpeg'})
    with urllib.request.urlopen(req, timeout=180) as r:
        return r.read()


def pick_model(api_key: str) -> str:
    """The first of MODELS this account takes, tried on the shortest sound."""
    for model in MODELS:
        try:
            generate(api_key, model, f'{STYLE} One tiny soft glassy tick.', 0.5)
            return model
        except urllib.error.HTTPError as e:
            reason = e.read().decode(errors='replace')[:200]
            if e.code in (401, 402, 429):
                sys.exit(f'ElevenLabs said {e.code}: {reason}')
            print(f'  {model} not taken ({e.code}): {reason}')
    sys.exit('No sound-effects model was accepted.')


def finish(mp3: bytes, dest: pathlib.Path, loop: bool) -> None:
    """The take as it came (mp3) and as the app would play it: mono Ogg Opus, silence cut at both ends."""
    dest.with_suffix('.mp3').write_bytes(mp3)
    trim = [] if loop else ['-af', 'silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.005,'
                                     'areverse,silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.005,areverse']
    with tempfile.TemporaryDirectory() as d:
        src = pathlib.Path(d, 'in.mp3')
        src.write_bytes(mp3)
        subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', str(src), *trim, '-ac', '1', '-ar', '48000',
                        '-c:a', 'libopus', '-b:a', '96k', str(dest.with_suffix('.ogg'))], check=True)


# Makes TAKES takes of each sound named (all of them where none is), skipping one whose takes are all there unless
# --again, into OUT or the folder after --out, and records each sound's prompt in prompts.json there.
def main() -> None:
    args = sys.argv[1:]
    out = OUT
    if '--out' in args:
        out = pathlib.Path(args[args.index('--out') + 1]).expanduser()
        args = [a for i, a in enumerate(args) if a != '--out' and (i == 0 or args[i - 1] != '--out')]
    again = '--again' in args
    wanted = [a for a in args if not a.startswith('--')] or list(SOUNDS)
    unknown = [w for w in wanted if w not in SOUNDS]
    if unknown:
        sys.exit(f'Not a sound here: {", ".join(unknown)}. They are: {", ".join(SOUNDS)}')
    out.mkdir(parents=True, exist_ok=True)
    record_path = out / 'prompts.json'
    record = json.loads(record_path.read_text()) if record_path.exists() else {}
    api_key = key()
    model = pick_model(api_key)
    print(f'> {model}, {TAKES} takes each, into {out}')
    for event in wanted:
        seconds, what = SOUNDS[event]
        if not again and all((out / f'{event}-{n}.ogg').exists() for n in range(1, TAKES + 1)):
            continue
        text = f'{STYLE} {what}'
        for n in range(1, TAKES + 1):
            try:
                finish(generate(api_key, model, text, seconds), out / f'{event}-{n}', event in LOOPS)
            except urllib.error.HTTPError as e:
                sys.exit(f'ElevenLabs said {e.code} for {event}: {e.read().decode(errors="replace")[:300]}')
        record[event] = {'model': model, 'seconds': seconds, 'prompt': text, 'takes': TAKES}
        record_path.write_text(json.dumps(record, indent=2) + '\n')
        print(f'ok {event}')
    print(f'ok {len(wanted)} sounds in {out}')


if __name__ == '__main__':
    main()
