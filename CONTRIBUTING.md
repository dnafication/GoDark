# Contributing to GoDark

Thanks for helping out. Bug reports, fixes and ideas are all welcome.

## Before you start

- GoDark turns displays off with **private CoreGraphics API**, so it can't go on the Mac App Store and a macOS update can break it. See the README.
- Read the "Built-in display safety net" section of [CLAUDE.md](CLAUDE.md). It explains how the app avoids leaving someone with no screen. Please don't weaken `restoreBuiltInIfStranded()` or the rule that refuses to turn off the last active display. If your change touches either, say so in the PR.
- For anything bigger than a small fix, open an issue first so we can agree on the approach.

## Setting up

1. Fork and clone the repo, then open `GoDark.xcodeproj`.
2. Under **Signing & Capabilities**, choose your own team. Change the bundle identifier too if Xcode can't register `com.dnafication.GoDark` for you. Please don't commit those changes.
3. Build with **⌘R**, or from the terminal as described in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Testing

There is no test target, and display behaviour can only be checked on real hardware. In your PR, describe what you tried: which displays, whether you plugged and unplugged monitors while one was off, and whether the Mac is Apple silicon or Intel.

## Pull requests

- Keep each PR focused, and match the style and comment density of the surrounding code.
- Confirm that `xcodebuild -project GoDark.xcodeproj -scheme GoDark build` succeeds.
- Update the README or developer guide if behaviour changes.

## Logs and privacy

Logs can include display identifiers. Check them before pasting into an issue, and remove anything you don't want public.

## Licence

By contributing you agree that your work is released under the [MIT licence](LICENSE).
