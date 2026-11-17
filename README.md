# DRooz for Apple TV

**Your DLRooz movies and series on Apple TV.** A native tvOS port of [DRooz for Android TV](https://github.com/AliKarami/DRooz-AndroidTV): the same site client, the same «ادامه تماشا» logic and the same player features, built with SwiftUI and Apple's own video player.

- **Home** with a focus-following hero, «ادامه تماشا» first (OK plays the right episode at the right second; hold OK for details or to remove it), then featured films, updated series, new films and series, popular, IMDb top, dubbed and kids rows.
- **Series / Films / My List** grids with infinite scroll and the site's categories as chips.
- **Title pages** with the adaptive play button («ادامه فصل ۲ قسمت ۷»…), seasons, numbered episodes with ✓ and progress, original ↔ دوبله, «لیست من», suggestions.
- **Search** with the Apple TV keyboard and Siri dictation, recent searches.
- **Player**: Apple's native player (Siri Remote scrubbing, ±10 s, speed, audio tracks incl. 5.1 and Persian dub) plus, in the transport bar: subtitles Farsi / English / **both** / Farsi for dub with size, colour, background and ±0.5 s sync; quality with the site's labels; audio boost (the site's loudness map); episodes; next episode with an up-next countdown; resume; automatic recovery when a stream key expires.
- Persian, right-to-left UI in Vazirmatn; titles keep their original names.

## Requirements

- Apple TV HD or 4K on **tvOS 17** or newer.
- A DLRooz account.

## Project layout

| Path | What |
|---|---|
| `Packages/DroozKit` | Swift package: HTTP + cookie handling, login, HTML parsers, watch-state rules, stores. Unit tests run against the Android project's sanitized fixtures. |
| `App/Sources` | The SwiftUI tvOS app (screens, player). |
| `App/Resources` | Fonts (Vazirmatn, OFL) and the asset catalog (layered app icon, top shelf). `scripts/make_icons.py` regenerates the icons. |
| `project.yml` | [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec; the `.xcodeproj` is generated, not committed. |

Build locally on a Mac with Xcode 26:

```bash
brew install xcodegen
BUNDLE_ID=com.sammhd.drooz DEVELOPMENT_TEAM=<your team id> xcodegen generate
open DRooz.xcodeproj
```

Run the package tests with `cd Packages/DroozKit && swift test`.

## Releasing to TestFlight

The **TestFlight** GitHub Actions workflow archives the app on a macOS runner and uploads it to App Store Connect with Xcode's cloud signing. One-time setup:

1. **Apple Developer**: in [Certificates, Identifiers & Profiles → Identifiers](https://developer.apple.com/account/resources/identifiers/list), register an App ID with the bundle ID `com.sammhd.drooz` (or your own; then set the repository variable `BUNDLE_ID` to it).
2. **App Store Connect**: [Apps → +  → New App](https://appstoreconnect.apple.com/apps), platform **tvOS**, any unique name (e.g. *DRooz TV*), that bundle ID, SKU e.g. `drooz-tv`.
3. **API key**: App Store Connect → Users and Access → Integrations → App Store Connect API → generate a team key with the **Admin** role (cloud signing needs it). Download the `.p8` once.
4. **GitHub secrets** (repository → Settings → Secrets and variables → Actions):
   - `ASC_KEY_ID` – the key ID
   - `ASC_ISSUER_ID` – the issuer ID shown above the keys
   - `ASC_KEY_P8` – the full text of the `.p8` file
   - `APPLE_TEAM_ID` – your team ID (Membership details)
5. Run **Actions → TestFlight → Run workflow** (or push a tag like `v1.0.0`).
6. When processing finishes (5–30 min), open **TestFlight** in App Store Connect, add yourself as an internal tester, and install **TestFlight** on the Apple TV to get the build.

## Good to know

- DRooz is an **unofficial** app made by fans; it isn't affiliated with DLRooz. You need your own subscription.
- Your password and the site's session cookies are stored in the Apple TV's Keychain and are only ever sent to the DLRooz site.
- DLRooz allows a limited number of devices per account; the Apple TV counts as one and keeps its device cookie across logins.
- Audio boost on Apple TV evens out loudness by lowering loud scenes to match quiet dialogue (the system player cannot amplify); raise the TV volume a little if it feels quiet, or turn it off in Settings or the player's menu.
