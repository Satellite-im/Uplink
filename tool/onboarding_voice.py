#!/usr/bin/env python3
"""Speaks the walkthrough's words with ElevenLabs, once, at build time: Ghost Keyboard's tool/onboarding_voice.py (itself
Ghost.md's) for Uplink, with the same voice (Jessica), model (Eleven v4, else multilingual v2) and settings.

The words live in lib/onboarding/narration.dart; this writes assets/onboarding/<page>.mp3 (mono, 64 kbps, as
ElevenLabs makes it) and assets/onboarding/narration.json saying which words, model and voice made each file, and
only remakes a page whose words changed (or with --again).

The key: $ELEVENLABS_API_KEY, else ~/.elevenlabs-key as Ghost.md keeps it. Never an argument, never printed.

    python3 tool/onboarding_voice.py
    python3 tool/onboarding_voice.py --page welcome --again

"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import sys
import urllib.error
import urllib.request

API = "https://api.elevenlabs.io/v1"
ROOT = pathlib.Path(__file__).resolve().parents[1]
WORDS = ROOT / "lib" / "onboarding" / "narration.dart"
OUT = ROOT / "assets" / "onboarding"
MANIFEST = OUT / "narration.json"
PREFERRED = "eleven_v4"
FALLBACK = "eleven_multilingual_v2"
VOICE = "cgSgspJ2msm6clMCkdW9"
VOICE_NAME = "Jessica"
SETTINGS = {"stability": 0.5, "similarity_boost": 0.75, "style": 0.2, "use_speaker_boost": True}


# The ElevenLabs key, from the environment or ~/.elevenlabs-key; stops with why where there is none.
def key() -> str:
    value = os.environ.get("ELEVENLABS_API_KEY", "").strip()
    if not value:
        path = pathlib.Path.home() / ".elevenlabs-key"
        value = path.read_text().strip() if path.exists() else ""
    if not value:
        sys.exit("No ElevenLabs key: set ELEVENLABS_API_KEY or put it in ~/.elevenlabs-key.")
    return value


# One request to ElevenLabs: a POST of `body` as JSON where there is one, else a GET. The answer's bytes; stops
# with what ElevenLabs said where it refused.
def call(path: str, token: str, body: dict | None = None) -> bytes:
    request = urllib.request.Request(
        f"{API}{path}",
        data=json.dumps(body).encode() if body else None,
        headers={"xi-api-key": token, "Content-Type": "application/json", "Accept": "*/*"},
        method="POST" if body else "GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=180) as answer:
            return answer.read()
    except urllib.error.HTTPError as error:
        sys.exit(f"ElevenLabs said {error.code} for {path.split('?')[0]}: {error.read().decode(errors='replace')[:400]}")


# What is said on each page, by the page's name: every `'name': 'words',` line of the Dart file WORDS.
def scripts() -> dict[str, str]:
    found = {}
    for match in re.finditer(r"^\s*'(\w+)':\s*'((?:[^'\\]|\\.)*)',\s*$", WORDS.read_text(), re.M):
        found[match.group(1)] = match.group(2).replace("\\'", "'")
    if not found:
        sys.exit(f"No words found in {WORDS}.")
    return found


# The model to speak with: PREFERRED where this account has it, else FALLBACK.
def model(token: str) -> str:
    ids = {m.get("model_id") for m in json.loads(call("/models", token))}
    return PREFERRED if PREFERRED in ids else FALLBACK


# Speaks each page whose words changed since it was last made (all of them with --again, one with --page), removes
# the sound of a page that is gone, and writes the manifest of what was made from which words.
def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--page")
    parser.add_argument("--again", action="store_true")
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    manifest = json.loads(MANIFEST.read_text()) if MANIFEST.exists() else {}
    files = manifest.get("files", {})
    words = scripts()
    token = key()
    chosen = model(token)
    made = 0
    for page, text in words.items():
        if args.page and page != args.page:
            continue
        digest = hashlib.sha256(text.encode()).hexdigest()[:16]
        target = OUT / f"{page}.mp3"
        if not args.again and target.exists() and files.get(page, {}).get("words") == digest:
            continue
        audio = call(f"/text-to-speech/{VOICE}?output_format=mp3_44100_64", token, {"text": text, "model_id": chosen, "voice_settings": SETTINGS})
        target.write_bytes(audio)
        files[page] = {"words": digest, "model": chosen, "voice": VOICE, "bytes": len(audio)}
        made += 1
        print(f"ok {page}: {len(audio)} bytes")
    for gone in [p for p in files if p not in words]:
        files.pop(gone)
        (OUT / f"{gone}.mp3").unlink(missing_ok=True)
    MANIFEST.write_text(json.dumps({"made": "tool/onboarding_voice.py", "voice": {"id": VOICE, "name": VOICE_NAME}, "files": files}, indent=2) + "\n")
    print(f"{made} made, {len(words) - made} as they were")


if __name__ == "__main__":
    main()
