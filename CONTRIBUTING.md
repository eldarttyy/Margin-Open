# Contributing to Margin

Thanks for helping. Margin is small, and most useful changes are small too: one
app's edges, one website, one bug on one Mac.

## Ways to help

- **Try it and report what happens.** Margin relies on a private Apple framework,
  so reports from different MacBooks and macOS versions are worth a lot. Open an
  issue with the output of `Margin.app/Contents/MacOS/Margin --diagnose`.
- **Add or fix an app pack.** The ready-made edges for one app. Usually 5 to 15
  lines. See below.
- **Add a site pack.** The same, for a website in the browser.
- **Pick up an issue.** Ones labelled `good first issue` need no knowledge of the
  gesture engine.

Before a large change, such as a new gesture or a new kind of binding, open an
issue first so we can agree on the shape.

## Setup

You need a MacBook on macOS 15 or later and the Xcode Command Line Tools.

```sh
git clone https://github.com/eldarttyy/Margin-Open.git
cd Margin-Open
swift test                       # the logic, no hardware needed
scripts/build-app.sh --dev       # builds build/Margin.app with the test tools
open build/Margin.app
```

Use `--dev` for your own copy. It keeps the Accessibility grant across rebuilds
and adds the command line tools used below. Never share a `--dev` build.

## Where things are

| Path | What it holds |
| --- | --- |
| `Sources/MarginCore` | Pure logic: zones, the gesture engine, settings, packs, menu matching. No AppKit. Unit tested. |
| `Sources/Margin` | The app: menu bar, settings windows, sending keys, reading menus. |
| `Sources/CMargin` | A C shim over Apple's private MultitouchSupport framework. |
| `plugins/blender` | The Blender add-on (GPL-3.0-or-later). |
| `Tests/MarginCoreTests` | Swift tests. `Tests/blender` runs inside Blender. |

## Adding an app pack

An unknown app already gets the universal edges (scroll, zoom, undo, tabs), and
Margin finds its zoom and tab commands in its menus. A pack is only for what
that misses.

1. Find the app's bundle ID: `osascript -e 'id of app "Sketch"'`.
2. Add an `AppPack` to `Packs.all` in `Sources/MarginCore/Pro/Packs.swift`.
   Name only the edges you change; the rest keep their universal meaning.

   ```swift
   AppPack(name: "Preview", bundleIDs: ["com.apple.Preview"], bindings: [
       .topEdge: named("Pages", step("opt+down", "opt+up")),
       .bottomEdge: named("Documents", step("opt+pagedown", "opt+pageup")),
   ]),
   ```

   `step(forward, backward)` sends one key per notch, forward for right or up.
   `.semantic(.zoom)` and friends let Margin work out the how. Corners take
   `.buttons(tap:hold:)`.
3. Add the app's shortcuts to `Sources/MarginCore/Pro/AppShortcuts.swift`, so
   people can pick them in Settings by name. Every key you put on an edge should
   be in that list.
4. Check the keys against the real app. With the app open:

   ```sh
   build/Margin.app/Contents/MacOS/Margin --audit com.apple.Preview
   ```

   `MATCH` means the app's own menu has that shortcut. `NOMENU` means it doesn't,
   which is fine for keys an app handles without a menu item, but check them by hand.
5. Run `swift test`. The tests check that every shortcut parses and that no app
   is in two packs.

Rules that keep packs safe:

- An app goes in one pack only.
- Don't put a plain letter key on an edge in an app where people type. One
  accidental touch would type it.
- In apps used during calls, leave the top and bottom edges off.
- Use the app's default shortcuts, not ones you've customised.

## Adding a site pack

Site packs are in `Sources/MarginCore/Pro/Sites.swift`. Give it an `id`, the
`hosts` it lives on, its `bindings`, and `items` for the shortcut list. Video
sites can reuse `player()`. Put a more specific pack above a more general one on
the same host, and add a line to `SiteTests` for the address.

Browsers don't say when a text box on a page has focus, so built-in site
bindings must not send a key that types. Arrows and media keys are fine.

## The Blender add-on

`plugins/blender/margin_bridge.py` is tested inside Blender itself:

```sh
/Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup --python Tests/blender/test_bridge.py
```

## Pull requests

- Keep one change per pull request.
- `swift test` must pass. Add a test for new logic in `MarginCore`.
- Say what you tested on: Mac model, macOS version, and the app's version for a pack.
- Match the code around you. Comments say why, not what.

By contributing you agree your work is released under the repository's licenses:
MIT, and GPL-3.0-or-later for `plugins/blender`.
