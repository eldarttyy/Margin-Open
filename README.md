# Margin

Margin is a macOS menu bar app that turns the edges of your trackpad into
controls. Rest a finger on an edge, then slide.

This free, open-source version gives you:

- A volume slider on the edge of your choice
- Skipping tracks by sliding along an edge or tapping a corner
- The current song in your menu bar
- Haptic ticks, palm rejection and a held cursor while you slide

The full Margin app adds every other edge and corner action, per-app setups, and
deep app control such as Blender. That's Margin Pro, which is free until
December 1, 2026 and $12 a year after that. It isn't part of this repository.

## Build

You need macOS 15 or later and the Xcode Command Line Tools.

```sh
scripts/build-app.sh
open build/Margin.app
swift test
```

Rebuilding an ad-hoc signed app resets its Accessibility permission, so grant it
again after each build.

## How it works

`MarginCore` is the pure logic: zones, the gesture state machine and settings.
It has no AppKit or hardware code, so it's fully unit tested. `Margin` is the
app. `CMargin` is a thin shim over Apple's private MultitouchSupport framework,
which is what makes raw trackpad touches possible. That's also why Margin can't
be in the Mac App Store, and why a macOS update could break it.

## License

MIT. See `LICENSE`. The Margin name and logo aren't covered by that license.
