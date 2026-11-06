# 0003: The project's name

Status: open. The working name is `rss_`, and Weir is the leading candidate.

This record is kept open so that the reasons for each candidate are in one place. It is closed by a commit that changes the name, or by one that keeps `rss_` and says why.

## Why decide before the first release

The name reaches the app's bundle identifier, the data folder, the background service's label, the repository and everything written about the project. People who install a release will have data under it. Changing the name afterwards means moving their data and replacing their background service, so it is cheapest now.

## What a rename touches

| Where | Today |
|---|---|
| Bundle identifier | `local.rss_.app` |
| Background service label | `local.rss_.daemon` |
| Data folder | `~/.rss_`. `rss data move` moves data between folders, but it does not rename the anchor itself, so a migration for that is not built |
| Command line program | `rss`. It could keep that name, or take the project's |
| Repository and links in documents | `rss_` |

## What a good name needs

- Short, and easy to type as a command.
- Easy to say, and spelled the way it sounds.
- Fits a quiet reader that keeps your data on your own machine.
- Does not collide with a well-known program, in Homebrew or among readers.

## Candidates

| Name | Sound | Idea | Notes |
|---|---|---|---|
| **Weir** | "weer", rhymes with "beer" | A low dam that holds water back and lets it through at its own pace, as a reader controls the flow of feeds | Four letters, a good command. The `.app` and `.dev` domains are registered, and some are listed for sale |
| **Lede** | "leed", rhymes with "need" | The opening of a news story | Short and journalistic. The domains are registered. The spelling is not obvious to someone who has not met the word |
| Reedbed | "reed-bed" | Feeds are reeds, and a reedbed filters water | The most likely to be available. Longer, so its command would be shorter than the name |
| Tidings | "ty-dings" | An old, warm word for news | Friendly, and less distinctive. The domains are registered |
| Rill | "rill" | A small stream | Short. The domains are registered |
| Sheaf | "sheef" | A bundle of stalks, things gathered together | Also a mathematical term |

## How availability was checked

On 2026-11-06 each name was looked up for a registered `.app` and `.dev` domain, by asking for nameservers, and as a Homebrew formula or cask. GitHub's search was rate limited and gave no usable result. A domain with no nameservers can still be registered, and none of this is a trademark search. It narrows the list and proves nothing.

## Open questions

- Should the command keep the name `rss`, which says what the program is, or take the project's name?
- Should the data folder be named for the project, or keep a neutral name?
- Is a registered domain a reason to drop a name, or only a reason to pick a different address for the site?
