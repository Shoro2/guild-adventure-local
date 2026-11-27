# Third-party components

This repository holds Guild Adventure's installer and launcher (AGPL-3.0-or-later). What they download is not part of
it:

| Component | License | Where it comes from |
|---|---|---|
| Guild Adventure server package | AGPL-3.0-or-later as a whole; built from AzerothCore (GPL-2.0-or-later), mod-playerbots (GPL-2.0-or-later), mod-ah-bot-plus (GPL-2.0-or-later), mod-autolearn-skills (AGPL-3.0), OpenSSL (Apache-2.0), the MySQL client library (GPL-2.0 with the Universal FOSS Exception) and Boost (BSL-1.0); sources and their notices: `guild-adventure-server` | `guild-adventure-server` releases |
| MySQL Community Server 8.4 | GPL-2.0 | mysql.com |
| Microsoft Visual C++ Redistributable | Microsoft's license terms | microsoft.com (only when missing) |

Server data (maps, vmaps, mmaps, DBC) is extracted on your PC from your own World of Warcraft client and never leaves
it.
