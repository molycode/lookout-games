#!/usr/bin/env python3
"""Writes index.json, from which Lookout learns what it can download.

The index names the commit it describes, and Lookout fetches every file at that commit: raw.githubusercontent.com
caches each URL for minutes, so a file fetched from main could be older than the index that lists it. Run it with the
games, protocols and stores committed, then commit index.json on its own. With --check it writes nothing, as a pull
request is checked: a protocol script that differs from index.json must raise its version.
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
USAGE = "usage: make-index.py [--check]"
CONTENT = ("games", "protocols", "stores")
# Format 3 names Steam and GOG by its ids among the Windows facts; format 4 names every store in launch.stores.
FORMAT_THREE_IDS = (("steamAppId", "steam"), ("gogId", "gog"))
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


def named_stores(game):
    launch = game.get("launch") if isinstance(game.get("launch"), dict) else {}
    windows = launch.get("windows") if isinstance(launch.get("windows"), dict) else {}
    stores = launch.get("stores") if isinstance(launch.get("stores"), dict) else {}
    named = [store for field, store in FORMAT_THREE_IDS if field in windows]

    return named + [key for key in stores if not key.startswith("//")]


# Each game lists the stores it names that have a file here, so Lookout fetches them with it.
def read_games(stores):
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
        named = [store for store in named_stores(game) if store in stores]

        if named:
            games[key]["stores"] = named

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


# Only what the index needs; `lookout --check` from 1.7 reads the rest, which the latest release may not do yet.
def read_stores():
    stores = {}
    folder = ROOT / "stores"

    for path in entries(folder) if folder.is_dir() else []:
        key = path.stem

        if path.suffix != ".json" or not KEY.match(key):
            fail(f"stores/{path.name}: a store is a .json file named with small letters, digits, '-' and '_'")

        try:
            store = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            fail(f"stores/{path.name}: {error}")

        store_format = store.get("format") if isinstance(store, dict) else None

        if type(store_format) is not int or store_format < 1:
            fail(f"stores/{path.name}: needs a 'format' from 1")

        stores[key] = {"format": store_format, **describe(path)}

    return stores


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

    if arguments and not is_check:
        sys.exit(USAGE)

    if not is_check and git("status", "--porcelain", "--", *CONTENT):
        fail("games/, protocols/ or stores/ has uncommitted changes, which the index could not name a commit for")

    stores = read_stores()
    games = read_games(stores)
    protocols = read_protocols()

    for key, game in games.items():
        if game["protocol"] not in protocols:
            fail(f"games/{key}/game.json: its protocol '{game['protocol']}' is not in protocols/")

    check_versions(protocols)

    if is_check:
        print(f"make-index.py: {len(games)} games, {len(protocols)} protocols, {len(stores)} stores, ready to index")
    else:
        # The last commit that changed them, not HEAD: a run on top of an index commit then changes nothing.
        commit = git("log", "-1", "--format=%H", "--", *CONTENT)
        index = {"index": INDEX_FORMAT, "commit": commit, "games": games, "protocols": protocols, "stores": stores}

        (ROOT / "index.json").write_text(json.dumps(index, indent="\t", ensure_ascii=False) + "\n", encoding="utf-8")
        print(f"index.json: {len(games)} games, {len(protocols)} protocols, {len(stores)} stores at {index['commit'][:12]}")


main()
