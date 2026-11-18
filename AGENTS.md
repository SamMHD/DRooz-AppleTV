# AGENTS.md

Guidance for coding agents working in this repository. `CLAUDE.md` is a symlink to this file.

## What this is

DRooz is an unofficial tvOS client for the DLRooz streaming site (Persian UI, right-to-left), ported from the Android TV app. It scrapes the site's HTML, so most bugs are either parser mismatches or tvOS player quirks.

- `Packages/DroozKit`: the UI-free core (HTTP and cookies, login, parsers built on SwiftSoup, watch-state rules, stores). It supports macOS, so `swift test` runs without a simulator.
- `App/Sources`: the SwiftUI app. `AppModel` holds the session, `HomeModel` and `HomeView` handle Home, and `TitleScreen`, `ListScreen`, `SearchScreen`, `SettingsScreen` and `LoginScreen` are the other screens.
- `App/Sources/Player`: `PlayerSession` wraps `AVPlayerViewController` (transport-bar menus, resume, quality, audio, subtitles, next episode, stream-key recovery). `SubtitleOverlay` draws subtitles and the title heading.
- `project.yml`: XcodeGen spec and the single source of the app version (`MARKETING_VERSION`).

## Commands

```bash
xcodegen generate                                      # after changing project.yml or adding/removing files
cd Packages/DroozKit && swift test                     # parser and logic tests (fast, macOS)
xcodebuild -project DRooz.xcodeproj -scheme DRooz -destination 'generic/platform=tvOS' \
  CODE_SIGNING_ALLOWED=NO build                        # compile check without signing
```

The `.xcodeproj` and `App/Info.plist` are generated and git-ignored; never edit or commit them. Set `BUNDLE_ID=com.sammhd.drooz DEVELOPMENT_TEAM=K3F46GZX35` in the environment for `xcodegen generate` when signing matters.

## Conventions

- **Language:** user-facing strings are Persian and written inline. Titles keep their original (usually English) names. Numbers shown to users use Persian digits where the surrounding UI does.
- **Layout direction:** the app is RTL. Latin text such as titles is laid out LTR (see `isLatinTitle`). Check both directions when touching layout.
- **Fonts:** use `.vazir(size, weight)` and `TitleText`; don't use system fonts for Persian text.
- **State:** screen models are `@MainActor @Observable` classes. Async work that can be superseded (paging, reloads) must ignore stale results; see the `generation` counter in `ListScreen`.
- **Parsers:** every parser fix in `Parsers.swift` gets a test in `ParserTests.swift`, with a fixture under `Tests/DroozKitTests/Fixtures` when the HTML shape is new. Fixtures must be sanitized (no account names, cookies or tokens).
- **Comments** explain why, briefly, especially for platform workarounds. Keep them up to date when behaviour changes.
- Keep changes focused. Don't refactor unrelated code in a bug fix.

## tvOS player notes (learned the hard way)

- tvOS 27 opens transport-bar menus to the right even when the bar is mirrored for RTL, which pushes them off screen. `PlayerSession` sets `traitOverrides.layoutDirection = .leftToRight` on the player; menu rows still render RTL.
- The player's own title view overlaps its buttons on tvOS 27, so `transportBarIncludesTitleView = false` and `SubtitleOverlay` draws the heading. It follows the transport bar via `playerViewController(_:willTransitionToVisibilityOfTransportBar:with:)`.
- `transportBarCustomMenuItems` supports one level of nested `UIMenu`.
- HLS audio renditions report `displayName == "Unknown"`. The site's rendition name (`original`, `original-6CH`, `dubbed-fa`) is in `commonMetadata` under `AVMetadataKey.commonKeyTitle`; the dub and 5.1 rules depend on it.
- tvOS 27 adds a system **Subtitles** button (generated English captions) that apps can't hide. DRooz's subtitle menu uses the `character.bubble` icon so the two look different.

## Testing on devices

- The tvOS simulator playing video is heavy on a laptop. Keep simulator runs short, prefer a real Apple TV for player work, and shut the simulator down afterwards.
- A real Apple TV paired with Xcode can be driven from a UI-test target with `XCUIRemote` and `XCUIScreen` screenshots, and logs read with `xcrun devicectl device process launch --console`.
- Red lines along the top and bottom of the TV picture come from Xcode's device window (DeviceHub) staying connected, not from the app. Quit DeviceHub to clear them.
- A VPN on the Mac can stop Xcode from reaching the Apple TV.

## Releasing

- Merging to `main` triggers `.github/workflows/testflight.yml`, which archives and uploads an internal-only TestFlight build (once the App Store Connect key secrets are set; see the README). Bump `MARKETING_VERSION` in `project.yml` for a new version. Build numbers are minutes since 2026-01-01 UTC.
- To release from a Mac: archive with `CODE_SIGNING_ALLOWED=NO`, then `xcodebuild -exportArchive -allowProvisioningUpdates` with `method` `app-store-connect`, `destination` `upload` and `testFlightInternalTestingOnly` `true`. Cloud signing supplies the distribution certificate.
- The App Store Connect app record is named "Download Day" (tvOS, bundle ID `com.sammhd.drooz`, team `K3F46GZX35`).

## Never

- Never commit credentials, cookies, `.p8` keys or account details. Test accounts are passed as environment variables only.
- Screenshots added to the repo must not show account names, phone numbers or e-mail addresses.
- Don't push, merge or upload builds unless the person you're working with asked for it.
