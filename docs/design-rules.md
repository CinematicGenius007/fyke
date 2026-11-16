# Design rules

These rules are the source of truth for every Fyke interface: the macOS GUI today, and the Windows and Linux GUIs that are planned. They come from the [v2 design pass in Paper](https://app.paper.design/file/01M6R7CJ81MKH0TMWJ8KNC6QGX/p-9-0), board 00. Colors, fonts and radii live in [`gui/tokens.css`](../gui/tokens.css), which is exported from the same file. When a screen and this document disagree, the document wins and the screen is the bug.

New features belong inside the reader, not beside it. People open Fyke to read, so every capability is drawn into the three panes that already exist: the sidebar picks, the list narrows, the reader shows.

## Four principles

1. **Say it as a sentence.** Views and routines read as plain sentences with words you can tap: "Unread from Engineering about storage." There are no filter forms.
2. **Make it from what you see.** A view is a search you kept (⌘S). A routine starts from a view. An answer can become a routine. Nothing begins at an empty form.
3. **Show the recipe.** Every AI brief says who wrote it and with which recipe, and cites each claim. The recipe opens in place, and it can be edited and tried.
4. **Quiet until it matters.** Background work lives in one line at the foot of the sidebar. It speaks up only when you need to act, and it says what is safe.

## One set of measurements

| Element | Rule |
|---|---|
| Grid | 4 pt. Panes are 232 / 368 / flexible. The reading column is 640 wide. |
| Sidebar row | 32 high, padding 10, icon 14, gap 8, radius 6 |
| Indent | 10 + 22 × depth. 22 is the icon (14) plus the gap (8), so a child's text lines up with its parent's text. |
| Section label | 11 pt, weight 600, +0.06em tracking, capitals, muted color |
| Chip | 24 to 28 high, radius 6. Selected chips are filled; chips have no border. |
| Button | 32 high, radius 6. One primary button per view. |
| Popover | Radius 10, hairline border, shadow `0 12px 32px #0000001F` plus `0 2px 6px #00000014` |
| Type | Inter for interface text, Newsreader for reading, JetBrains Mono for code and values |
| Color | Blue (`unread`, #0A3CFF light) means unread and action. Purple (`read`, #5B2A9D light) means read, and nothing else. |

Use the named tokens, never raw values. A value that is missing from the tokens is added in Paper and exported, as [AGENTS.md](../AGENTS.md) describes.

### Indent is computed, never set per row

The indent for a depth is one value, computed from the formula above, and every row at that depth uses it. Sibling feeds under one folder must line up. A tree where siblings sit at 64 and 48 reads as two levels when it is one.

## Interaction rules

- **Undo instead of confirm.** A bulk or destructive action happens at once and offers Undo (⌘Z) in a toast. Ask first only when the action cannot be undone, such as deleting data from disk.
- **States say three things.** An empty, failed or in-progress state says what happened, what is safe, and the one next action. It appears inline, where the work is. There are no modal error dialogs.
- **One place for background work.** Jobs, refreshes and routine runs show in the Activity popover, which opens from the status line at the foot of the sidebar.
- **Every control has every state.** Rest, hover, pressed, focused (a visible keyboard ring), selected and disabled. Motion is short (120 to 200 ms, ease out) and is turned off when the system asks for reduced motion.
- **The keyboard reaches everything.** Every action has a menu item, and the frequent ones have shortcuts. ⌘K opens a palette of all of them.
- **Generated text is labeled.** AI output is marked as generated, names its writer and recipe, and links each claim to its source article.

## What changed from the first pass, and why

| Area | First pass | Now | Why |
|---|---|---|---|
| Layout | Full-width pages with 40px titles | The three panes, always | You never lose your place to manage something. |
| Sidebar | 42px rows, no icons, Settings as a row | 32px rows, 14px icons, status at the foot | Matches macOS density; about 30% more feeds are visible. |
| Views | A rule-builder form of outlined boxes | Search, then "Save as view"; the rule as a sentence | You see results before you commit to a rule. |
| Briefs | A Briefing page with cards | Today, read like an article, with citations | Every claim is one hover from its source. |
| Prompt or skill | Hidden in settings | A "recipe" linked from every brief, editable and testable | You fix a brief where you notice the problem. |
| Routines | A schedule form plus action checkboxes | When / Look in / Then, with a dry run on last week | You know what it will do before it runs. |
| Jobs and errors | A separate Jobs page and dialogs | One Activity popover; inline states | One place to look; failures say what is safe. |

## Simplifying a screen

Before adding a control, check in this order:

1. Can it be removed? A setting nobody changes is a default.
2. Can it start from something the person already sees, such as the current search or the selected feed?
3. Can it be said as one sentence with editable words instead of a form?
4. Does it fit in an existing pane, popover or menu instead of a new page?
5. Does the screen still have exactly one primary action?

A change that fails one of these needs a reason recorded beside the design.
