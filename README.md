# Lookout games

The game descriptions and protocol scripts that [Lookout](https://github.com/molycode/lookout), a game server browser
for Linux, downloads. Lookout itself knows no game: its download dialog lists what is here, and installs, updates and
removes it.

## What is here

- `games/<key>/game.json`: a game's description. It names the game, its protocol and its masters, which of a server's
  rules hold its name, map and players, and how the game is started to join a server. `"//<field>"` beside a field
  is a comment on it.
- `games/<key>/icon.png`: the game's icon, square and at least 128 px, with `icon-licence.txt` beside it saying where
  it comes from and under what licence. A game without an icon is shown with a stand-in.
- `protocols/<name>.lua`: a protocol script, which the games that speak it name. It runs in a sandbox and only turns
  bytes into requests and replies; Lookout does the networking.
- `index.json`: what Lookout downloads from. `tools/make-index.py` writes it after every merge; never edit it by hand.

## Adding a game

A game whose servers speak a protocol already here needs only its folder: `game.json`, and its icon with the licence if
there is one. The folder's name is the game's key, made of small letters, digits, `-` and `_`; it is also the name
Lookout keeps the game's settings under, so it never changes once published.

The easiest way to write `game.json` is in Lookout: click the gamepad button beside the "+" above the server list,
or right-click a game to start from its description. The editor checks the text as you type and lists every field
beside it. A new game you save there is in `~/.local/share/lookout/games/<key>/game.json`, ready to copy here.

A game on a protocol that is not here yet adds `protocols/<name>.lua` as well. Captured replies from a real master and
server, as Lookout's protocol tests use them, make it much easier to review.

Before opening a pull request, check the folder with Lookout 1.2 or newer:

    lookout --check /path/to/lookout-games

It prints every problem Lookout would have with the files and exits with an error when there is one. The same check
runs on every pull request.

## Licence

The descriptions and scripts are MIT licensed, see `LICENSE`. Each icon carries its own licence in its
`icon-licence.txt`; game names, logos and marks belong to their owners.
