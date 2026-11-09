# 0003: The project's name

Status: decided. The project is **Fyke**. Before the decision the working name was `rss_`, which still names the checkout folder and some internal identifiers. Everything a person sees or types says Fyke.

## Why decide before the first release

The name reaches the app's bundle identifier, the data folder, the background service's label, the repository and everything written about the project. People who install a release will have data under it. Changing the name afterwards means moving their data and replacing their background service, so it is cheapest before any release exists.

## The choice

A fyke is a funnel-shaped fishing net: fish swim in and cannot swim out. The reader works the same way. Feeds flow in and stay on your own machine. It is four letters, easy to type as a command, spelled as it sounds, and shares nothing with a well-known reader.

## What the name touches

| Where | Name |
|---|---|
| Command line program | `fyke` |
| Daemon, socket and log | `fyked.sock`, `fyked.log`, `fyked.lock` |
| Data folder | `~/.fyke`, or `$FYKE_HOME` when set. The database is `fyke.db` |
| Environment variables | `FYKE_HOME`, `FYKE_KEYS`, `FYKE_SNAPSHOT` and the other `FYKE_` variables |
| Bundle identifier and service label | `local.fyke.app`, `local.fyke.daemon` |
| macOS app | `Fyke.app` |
| User agent and robots.txt token | `fyke` |
| MCP server name | `fyke` |
| Repository and links in documents | `fyke` |

Data from builds made before the rename lives in `~/.rss_`, under the old file names. The first `fyke` command moves it to `~/.fyke`, renames the database files, and leaves a link behind. If both folders hold data, `~/.fyke` is used and the old folder is untouched. [The architecture document](../architecture.md) lists the cases.

## Not changed

The checkout folder, the Zig module and file names, and internal identifiers keep the old working name. They are not visible to a person using or contributing to the project, and renaming them would add churn with no benefit. `docs/rss-primer.md` and every mention of RSS the file format are unchanged, because they refer to the format.

## What a good name needed

- Short, and easy to type as a command.
- Easy to say, and spelled the way it sounds.
- Fits a quiet reader that keeps your data on your own machine.
- Does not collide with a well-known program, in Homebrew or among readers.

## Candidates considered

| Name | Idea | Outcome |
|---|---|---|
| **Fyke** | A funnel net that lets fish in and not out: feeds come in and stay local | Chosen |
| Weir | A low dam that lets water through at its own pace | Not chosen. The site and logo were first designed for it, and were reworked for Fyke |
| Lede | The opening of a news story | Spelling is not obvious to someone who has not met the word |
| Reedbed | Feeds are reeds, and a reedbed filters water | Longer than a good command |
| Tidings | An old, warm word for news | Less distinctive |
| Rill | A small stream | Short, but plain |
| Sheaf | A bundle of stalks | Also a mathematical term |

## How availability was checked

On 2026-11-06 each name was looked up for a registered `.app` and `.dev` domain, by asking for nameservers, and as a Homebrew formula or cask. GitHub's search was rate limited and gave no usable result. A domain with no nameservers can still be registered, and none of this is a trademark search. It narrows the list and proves nothing.

On 2026-11-09 `brew search fyke` found no formula or cask with that name. The site is served from `fyke.cinematicgenius007.com`, a subdomain of an address the project already owns. No trademark search was made, so check one before publishing a release.
