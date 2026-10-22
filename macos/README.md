# ChatGPT Multi-Accounts for macOS

The macOS app and the `chatgpt-multi` command, in one Swift package. How to install and use them is in the [main README](../README.md); the rules they follow are in [docs/how-it-works.md](../docs/how-it-works.md).

## Build and test

You need macOS 13 or later and Xcode or the Command Line Tools. Run these in this folder:

```bash
swift build
swift test                                             # the account logic, with a pretend ChatGPT
/usr/bin/python3 -m unittest discover -s Tests/cli -v  # the command end to end, against the debug build
scripts/build.sh      # build "ChatGPT Multi-Accounts.app" and chatgpt-multi into build/
scripts/install.sh    # build, install into ~/Applications and ~/.local/bin, and open the app
scripts/release.sh    # build and pack the zip files and checksums for a GitHub release into build/release/
```

The binaries are universal (Apple silicon and Intel). The app has an ad-hoc signature, so it runs on the Mac that built it. It isn't signed with a Developer ID or notarized, so a downloaded copy shows a security warning the first time it opens (the [main README](../README.md#first-open) explains it).

`scripts/build.sh` puts the command inside the app (`Contents/MacOS/chatgpt-multi`) as well as in `build/`; the app's **Settings → Install in ~/.local/bin** links to the copy inside the app.

## Demo and screenshots

```bash
open -n "build/ChatGPT Multi-Accounts.app" --args --demo   # try it with synthetic accounts
../docs/screenshots/make-screenshots.sh                    # make every README image again from synthetic data
```

## Release

1. Raise `VERSION` and `BUILD` at the top of `scripts/build.sh`.
2. Run `scripts/release.sh`.
3. Commit, push, and publish the files: `gh release create v<version> build/release/* --title "ChatGPT Multi-Accounts <version>" --notes-file <notes>`.

## Source

- `Sources/MultiAccountsCore`: the account list, opening and closing accounts' copies of ChatGPT, finding running copies (`ChatGPTControl`), reading who a folder is signed in to (`SignIn`), the two app-wide ChatGPT settings (`SharedSettings`, `BrowserExtension`), and the pretend ChatGPT for the demo and tests.
- `Sources/chatgpt-multi`: the command, with its browser-extension guard.
- `Sources/ChatGPTMultiAccounts`: the AppKit app with SwiftUI views: the window (`MainView`), settings (`SettingsView`), the menu bar item and Dock menu (`Menus.swift`) and the screenshot renderer (`Screenshots.swift`).
- `Tests/MultiAccountsCoreTests`: unit tests for the core.
- `Tests/cli`: end-to-end tests for the command (Python, standard library only).
- `Resources/AppIcon.icns`: the app icon, exported from [`assets/icon/AppIcon.svg`](../assets/icon/AppIcon.svg) by `assets/icon/make-icons.sh`. Edit the SVG, not this file.
