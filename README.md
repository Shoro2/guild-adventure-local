# Guild Adventure (local)

Play Guild Adventure alone on your own Windows PC: a guild management game on a World of Warcraft 3.3.5a server
where you lead a guild of up to 39 bots. This repository holds only the installer and the launcher; the server and the
game's code are in `guild-adventure-server`.

> **Disclaimer.** Guild Adventure is a fan project. It is not affiliated with, endorsed by or sponsored by Blizzard
> Entertainment. World of Warcraft and Blizzard Entertainment are trademarks or registered trademarks of Blizzard
> Entertainment, Inc. This repository contains no Blizzard game files. You need your own legally obtained World of
> Warcraft 3.3.5a (build 12340) client; the installer extracts the server data from it on your PC. For private use
> only. Do not use any part of this project with official Blizzard services.

## What you need

- Windows 10 or 11, 64-bit, and about 8 GB free disk space
- Your own World of Warcraft 3.3.5a client, build 12340 (any locale)
- An internet connection during the installation
- Optional: "AC Data v20 enUS" files

## Install

1. Download this repository (Code, Download ZIP) and unpack it, for example to `C:\Games\GuildAdventure`. The folder's
   path may hold only letters A-Z, digits and the usual signs: MySQL does not start from a path with other letters
   (for example your Desktop, when your Windows user name has Cyrillic letters or umlauts).
2. Double-click `Install.cmd`.
3. Choose your client folder (the one with `Wow.exe`).
4. Say whether you already have server data (see below); if not, the installer extracts it from your client.
5. Enter an account name and password when asked.

The installer then:

- checks that the client is 3.3.5a build 12340;
- downloads the Guild Adventure server (from `guild-adventure-server`'s releases), MySQL 8.4 (from mysql.com) and, if
  missing, the Microsoft Visual C++ runtime (it asks for administrator rights for that one only);
- extracts the server data (maps, vmaps, mmaps) from your client into the install folder if not provided; this takes one to three
  hours, and your client is only read;
- sets up the databases, the server configuration and your account, all on 127.0.0.1;
- copies the `GuildAdventure` addon into your client and sets its realmlist to 127.0.0.1 (the old `realmlist.wtf`
  is kept as `realmlist.wtf.before-guild-adventure`);
- creates a desktop shortcut and starts the game.

If it stops (an error, a closed window), run `Install.cmd` again: it goes on where it stopped.

**You already have server data?** Right after the client folder the installer asks whether you have the server data
of an AzerothCore server for 3.3.5a (a folder with `dbc`, `maps`, `vmaps` and `mmaps`). Answer Yes and choose that
folder, and nothing is extracted (which saves the hours of the mmaps). The folder is used where it is and is never
changed; keep it as long as you play. Without the question: `Install.cmd -DataDir "D:\path\to\that\folder"`, or
`Install.cmd -Extract` to extract from the client.

Everything except the addon and the realmlist goes into the folder `game` beside these files. Free ports are chosen if
the usual ones (3724, 8085, 3306) are taken by something else.

## Play

`Start.cmd` (or the desktop shortcut) starts the database, the login server and the world server, then your client.
Log in with your account; your first character becomes the guild leader. `Stop.cmd` saves and stops everything.

How to play, from your first bots to raids: the
[player guide](https://github.com/Shoro2/guild-adventure-server/blob/main/guide/README.md) in `guild-adventure-server`.

## Update

From version 0.1.1 on, `Start.cmd` looks on GitHub for a newer version each time it starts (a few seconds at most;
without a connection it starts as it is). When there is one it asks whether to update now: Yes downloads the new files
and the new server and starts the game afterwards, No starts as it is and asks again for the next version.

By hand (and once from version 0.1.0, which has no such check): run `Stop.cmd`. Download this repository again
(Code, Download ZIP), unpack it and copy its files into your old folder, replacing the old ones; the folder `game`
stays as it is. Then run `Install.cmd`: it sees the new version, downloads the new server and replaces the old one.
Your databases, characters, account and server data stay; nothing is extracted again. `Start.cmd` refuses to start
an installation that is older than its files and asks for that `Install.cmd` run.

## Remove

Run `Stop.cmd`, delete this folder and the desktop shortcut, delete `Interface\AddOns\GuildAdventure` from your client
and rename `realmlist.wtf.before-guild-adventure` back to `realmlist.wtf`.

## License

AGPL-3.0-or-later, see [LICENSE](LICENSE); third-party components: [NOTICE.md](NOTICE.md).
