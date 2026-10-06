#!/usr/bin/env python3
"""Writes index.json, from which Lookout learns what it can download.

The index names the commit it describes, and Lookout fetches every file at that commit: raw.githubusercontent.com
caches each URL for minutes, so a file fetched from main could be older than the index that lists it. Run it with the
games and protocols committed, and Lookout's latest release as --lookout-version, then commit index.json on its own;
Lookout tells its users when the index names a newer one. With --check it writes nothing, as a pull request is checked:
a protocol script that differs from index.json must raise its version.
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
# The returned table's first fields, so a nested field of the same name is never taken for them.
HEADER = re.compile(r"^return \{\n\tapi = (\d+),\n(?:\tversion = (\d+),\n)?", re.MULTILINE)
VERSION_API = 2
LOOKOUT_VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+\Z")
USAGE = "usage: make-index.py --lookout-version X.Y.Z | --check"
# Lua's largest integer.
MAX_VERSION = 2**63 - 1


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

        headers = HEADER.findall(path.read_text(encoding="utf-8"))

        if len(headers) != 1:
            fail(f"protocols/{path.name}: needs one 'return {{' with 'api = <number>,' on the line after it")

        api = int(headers[0][0])
        protocol = {"api": api}

        if api >= VERSION_API:
            version = int(headers[0][1] or 0)

            if not 1 <= version <= MAX_VERSION:
                fail(f"protocols/{path.name}: needs 'version = <number>,' from 1 on the line after its api")

            protocol["version"] = version

        protocols[name] = {**protocol, **describe(path)}

    return protocols


# Against what was last indexed, so each index raises the version of every script it changes.
def check_versions(protocols):
    try:
        indexed = json.loads((ROOT / "index.json").read_text(encoding="utf-8")).get("protocols", {})
    except FileNotFoundError:
        indexed = {}
    except ValueError as error:
        fail(f"index.json: {error}")

    for name, protocol in protocols.items():
        old = indexed.get(name, {})
        old_version = old.get("version", 0)
        new_version = protocol.get("version", 0)

        if old and old.get("sha256") != protocol["sha256"] and (old_version or new_version) and new_version <= old_version:
            fail(f"protocols/{name}.lua: changed since index.json, so its version must be above {old_version}")


def main():
    arguments = sys.argv[1:]
    is_check = arguments == ["--check"]
    lookout_version = arguments[1] if len(arguments) == 2 and arguments[0] == "--lookout-version" else None

    if not is_check and lookout_version is None:
        sys.exit(USAGE)

    if lookout_version is not None and not LOOKOUT_VERSION.match(lookout_version):
        fail(f"--lookout-version {lookout_version}: must be a version such as 1.4.0")

    if not is_check and git("status", "--porcelain", "--", "games", "protocols"):
        fail("games/ or protocols/ has uncommitted changes, which the index could not name a commit for")

    games = read_games()
    protocols = read_protocols()

    for key, game in games.items():
        if game["protocol"] not in protocols:
            fail(f"games/{key}/game.json: its protocol '{game['protocol']}' is not in protocols/")

    check_versions(protocols)

    if is_check:
        print(f"make-index.py: {len(games)} games, {len(protocols)} protocols, ready to index")
    else:
        # The last commit that changed them, not HEAD: a run on top of an index commit then changes nothing.
        commit = git("log", "-1", "--format=%H", "--", "games", "protocols")
        index = {"index": INDEX_FORMAT, "commit": commit, "lookoutVersion": lookout_version, "games": games,
            "protocols": protocols}

        (ROOT / "index.json").write_text(json.dumps(index, indent="\t", ensure_ascii=False) + "\n", encoding="utf-8")
        print(f"index.json: {len(games)} games, {len(protocols)} protocols at {index['commit'][:12]}")


main()
