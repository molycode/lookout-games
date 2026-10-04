#!/usr/bin/env python3
"""Writes index.json, from which Lookout learns what it can download.

The index names the commit it describes, and Lookout fetches every file at that commit: raw.githubusercontent.com
caches each URL for minutes, so a file fetched from main could be older than the index that lists it. Run it with the
games and protocols committed, then commit index.json on its own.
"""

import hashlib
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
INDEX_FORMAT = 1
KEY = re.compile(r"[a-z0-9][a-z0-9_-]*\Z")
GAME_FILES = ("game.json", "icon.png", "icon-licence.txt")
API = re.compile(r"^\s*api\s*=\s*(\d+)\s*,", re.MULTILINE)


def fail(message):
    sys.exit(f"make-index.py: {message}")


def git(*args):
    return subprocess.run(["git", "-C", str(ROOT), *args], check=True, capture_output=True, text=True).stdout.strip()


def describe(path):
    data = path.read_bytes()
    return {"size": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def entries(folder):
    return sorted(entry for entry in folder.iterdir() if not entry.name.startswith("."))


def read_games():
    games = {}

    for folder in entries(ROOT / "games"):
        key = folder.name

        if not folder.is_dir() or not KEY.match(key):
            fail(f"games/{key}: a game is a folder named with small letters, digits, '-' and '_'")

        unknown = [entry.name for entry in entries(folder) if entry.name not in GAME_FILES]

        if unknown:
            fail(f"games/{key}: holds {', '.join(unknown)}; a game holds only {', '.join(GAME_FILES)}")

        if (folder / "icon.png").exists() != (folder / "icon-licence.txt").exists():
            fail(f"games/{key}: an icon.png needs its icon-licence.txt, and the other way round")

        try:
            game = json.loads((folder / "game.json").read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            fail(f"games/{key}/game.json: {error}")

        files = {name: describe(folder / name) for name in GAME_FILES if (folder / name).exists()}
        games[key] = {"name": game.get("name"), "format": game.get("format"), "protocol": game.get("protocol"), "files": files}

    return games


def read_protocols():
    protocols = {}

    for path in entries(ROOT / "protocols"):
        name = path.stem

        if path.suffix != ".lua" or not KEY.match(name):
            fail(f"protocols/{path.name}: a protocol is a .lua file named with small letters, digits, '-' and '_'")

        api = API.search(path.read_text(encoding="utf-8"))

        if api is None:
            fail(f"protocols/{path.name}: declares no api")

        protocols[name] = {"api": int(api.group(1)), **describe(path)}

    return protocols


def main():
    if git("status", "--porcelain", "--", "games", "protocols"):
        fail("games/ or protocols/ has uncommitted changes, which the index could not name a commit for")

    games = read_games()
    protocols = read_protocols()

    for key, game in games.items():
        if game["protocol"] not in protocols:
            fail(f"games/{key}/game.json: its protocol '{game['protocol']}' is not in protocols/")

    index = {"index": INDEX_FORMAT, "commit": git("rev-parse", "HEAD"), "games": games, "protocols": protocols}

    (ROOT / "index.json").write_text(json.dumps(index, indent="\t", ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"index.json: {len(games)} games, {len(protocols)} protocols at {index['commit'][:12]}")


main()
