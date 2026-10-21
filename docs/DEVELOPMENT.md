# Developing GoDark

You can build and run GoDark entirely from the terminal. Xcode doesn't need to be open, but it does need to be installed: `xcodebuild` comes with Xcode, not with the standalone Command Line Tools.

If `xcodebuild` complains about the developer directory, point it at Xcode once:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## Build

```sh
xcodebuild -project GoDark.xcodeproj -scheme GoDark -configuration Release \
  -derivedDataPath build build
```

The app is written to `build/Build/Products/Release/GoDark.app` (`build/` is git-ignored). The project has the maintainer's signing team set. Choose your own under **Signing & Capabilities** in Xcode (without committing the change), or build unsigned with `CODE_SIGNING_ALLOWED=NO`.

Without `-derivedDataPath`, a plain `xcodebuild -project GoDark.xcodeproj -scheme GoDark build` makes a Debug build in Xcode's DerivedData folder. To open that one:

```sh
open "$(xcodebuild -project GoDark.xcodeproj -scheme GoDark -showBuildSettings | awk '/ BUILT_PRODUCTS_DIR /{print $3}')/GoDark.app"
```

## Run

```sh
open build/Build/Products/Release/GoDark.app
```

Closing the window doesn't quit GoDark (that keeps the built-in display safety net running). If an older copy is still running, `open` just brings it to the front instead of launching your new build, so **quit it before relaunching**:

```sh
osascript -e 'quit app "GoDark"'
```

Quit it this way rather than with `killall`: a normal quit turns the built-in display back on.

## Rebuild and relaunch in one go

```sh
osascript -e 'quit app "GoDark"'
xcodebuild -project GoDark.xcodeproj -scheme GoDark -configuration Release \
  -derivedDataPath build build -quiet \
  && open build/Build/Products/Release/GoDark.app
```

## Install locally

```sh
cp -R build/Build/Products/Release/GoDark.app /Applications/
```

## Logs

After reproducing an issue:

```sh
log show --last 10m --info --predicate 'subsystem == "com.dnafication.GoDark"'
```

## Saved state

GoDark is sandboxed, so its preferences live in its container. To inspect them:

```sh
defaults read com.dnafication.GoDark
```

| Key | Contents |
| --- | --- |
| `knownDisplayNames` | Display names, cached because disabled displays vanish from `NSScreen` |

## Testing

There's no test target. Display behaviour can only be checked on real hardware: toggle displays, and plug and unplug monitors while one is off.
