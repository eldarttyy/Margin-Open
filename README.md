# Margin

Margin is a macOS menu bar app that turns the edges and corners of your trackpad
into controls that change with the app in front. Rest a finger on an edge, then
slide. It's free and open source, every feature of it.

- Volume, brightness, skipping tracks and the current song in your menu bar
- Smart Edges: edges bind to meanings like zoom, scroll and undo, and Margin reads
  each app's own menus to work out how to do them, so apps nobody has set up work
- Ready-made edges for more than 50 apps and a dozen websites, from Final Cut Pro
  to YouTube
- Your own setup for any app, a Caps Lock layer for a second set of edges, and
  deep Blender control through a small add-on
- Haptic ticks, palm rejection and a held cursor while you slide

## Install

Needs a MacBook running macOS 15 or later.

```sh
curl -fsSL https://margin-theta-five.vercel.app/install.sh | sh
```

Or build it yourself, below. Grant Accessibility access when Margin asks.

## Build

You need the Xcode Command Line Tools.

```sh
scripts/build-app.sh
open build/Margin.app
swift test
```

Rebuilding an ad-hoc signed app resets its Accessibility permission, so grant it
again after each build. `scripts/build-app.sh --dev` keeps the grant across your
own rebuilds and adds diagnostics.

## How it works

`MarginCore` is the pure logic: zones, the gesture state machine, settings, app
packs and menu matching. It has no AppKit or hardware code, so it's unit tested.
`Margin` is the app. `CMargin` is a thin shim over Apple's private
MultitouchSupport framework, which is what makes raw trackpad touches possible.
That's also why Margin can't be in the Mac App Store, and why a macOS update could
break it.

## License

MIT. See `LICENSE`. The Blender add-on in `plugins/blender` is GPL-3.0-or-later,
because it uses Blender's Python API. The Margin name and logo aren't covered by
either license.
