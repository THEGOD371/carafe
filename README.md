# Carafe

> A native macOS app for running Windows games on Apple Silicon,
> built around Apple's Game Porting Toolkit and Wine. Free and open
> source (MIT).

<!--
  TODO before tagging v0.1.8:
  Drop a hero screenshot in docs/screenshots/library.png and uncomment
  the line below. Recommended: the library grid with a few games
  installed, taken at 2× retina, 1600×1000 region.
-->
<!-- ![Carafe library view](docs/screenshots/library.png) -->

## What is Carafe?

Carafe lets you install and run Windows-only PC games on an
Apple-Silicon Mac with a single click. Under the hood it manages
**Wine prefixes** ("bottles"), pairs each one with the right Wine
build (Apple GPTK for graphics-heavy games, Wine Staging for
modern Chromium-based launchers like Steam), and installs the usual
runtime grab-bag (Visual C++, .NET, DirectX bits) via Winetricks.
Each game tile in the library is a one-click launch — Carafe
handles the Wine glue so you don't have to.

## Download

<!--
  TODO before tagging v0.1.8:
  Replace the URL below with the real GitHub Releases link.
  Generated automatically by the release workflow once the
  `THEGOD371/carafe` placeholder in `project.yml` (SUFeedURL) and
  `Carafe/App/SettingsView.swift` (AboutTab.githubURL) is replaced
  with the real repo slug.
-->

**[Download Carafe 0.1.8 (.dmg)](https://github.com/THEGOD371/carafe/releases/latest)**

## First-launch — Gatekeeper bypass

v0.1.x is signed ad-hoc (no paid Apple Developer ID yet). macOS
Gatekeeper will block the first launch with "Carafe can't be opened
because Apple cannot check it for malicious software." This is
expected.

**To bypass once:**

1. Drag `Carafe.app` from the DMG into `/Applications`.
2. In Finder, navigate to `/Applications`.
3. **Right-click** (or Ctrl-click) `Carafe.app` → **Open**.
4. macOS asks "Are you sure you want to open it?" → click **Open**.

macOS remembers your choice; subsequent launches go through
normally (double-click, Spotlight, Dock).

Power-user alternative — drop the quarantine attribute manually:

```bash
xattr -dr com.apple.quarantine /Applications/Carafe.app
```

Notarization is on the roadmap once we have a $99 Apple Developer
account; that'll make this step unnecessary.

## System requirements

| Requirement | Minimum                                      |
| ----------- | -------------------------------------------- |
| macOS       | 14.0 Sonoma                                  |
| Hardware    | Apple Silicon (M1/M2/M3/M4) — Intel unsupported |
| Disk        | ~10 GB free for GPTK + Homebrew + first bottle |
| Network     | Required for first run (downloads installers) |

GPTK and Homebrew are installed by Carafe's onboarding flow if not
already present; you don't need to set them up manually.

## What works

- Single-player and indie Windows games without kernel-level
  anti-cheat.
- Steam (Wine Staging bottles only; sign-in is currently
  cumbersome — see Known limitations).
- Per-bottle compatibility config (DXVK / D3DMetal / DLL overrides
  / Windows version).
- Per-game overrides on top of the bottle defaults.
- Cover art auto-fetched from SteamGridDB (free API, your key
  goes in via Settings → Integrations).
- Auto-update via Sparkle once we ship the EdDSA-signed appcast.

## Known limitations

- **No anti-cheat support.** Vanguard, BattlEye, Easy Anti-Cheat,
  and similar kernel-level anti-cheat systems require Windows
  drivers Wine can't host. Multiplayer games that gate behind them
  will not work and are explicitly out of scope.
- **Steam sign-in is still experimental.** Wine Staging keeps the
  modern CEF/Chromium UI alive better than GPTK, and Carafe applies
  the GPU/DLL workaround set automatically. If Steam self-updates and
  the window goes black again, rerun "Install Steam in Bottle…" for
  that bottle before launching Steam.
- **32-bit Windows apps won't run on GPTK bottles.** GPTK is
  64-bit-only. Use Wine Staging if your app is 32-bit; Carafe
  detects the binary's architecture and refuses to launch
  mismatches with a clear error.
- **Steam Family Sharing and other DRM edge cases** may behave
  oddly — Steam itself doesn't always cope well with Wine's
  filesystem semantics.

## Building from source

You need Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
xcodegen generate
open Carafe.xcodeproj
```

Then build & run the `Carafe` scheme.

### Generating a release .dmg

```bash
./Tools/build-dmg.sh
# → Carafe-0.1.8.dmg in the repo root
```

The script auto-installs `create-dmg` via Homebrew on first run,
regenerates the procedural DMG background, builds the app in
Release configuration, and packages it. See [TESTING.md](TESTING.md)
for the full manual test plan.

### Regenerating the app icon

The app icon is drawn procedurally:

```bash
swift Tools/generate-app-icon.swift
```

This rewrites `Carafe/Resources/AppIcon.icns`. The script also runs
`iconutil` so all 10 macOS icon sizes are populated — do NOT switch
back to using an `AppIcon.appiconset` inside the asset catalog,
that path silently drops 6 of the 10 sizes (see commit history /
TESTING.md A-bis for the gory details).

## Releasing

Releases are cut by pushing a `v*` tag:

```bash
git tag v0.1.8
git push --tags
```

The [`.github/workflows/release.yml`](.github/workflows/release.yml)
workflow runs on the tag push, builds the .dmg, signs it with the
Sparkle EdDSA key (from the `SPARKLE_ED_PRIVATE_KEY` repo secret),
generates `appcast.xml`, and attaches both to a new GitHub Release.

See TESTING.md → "Sparkle release engineering" for the one-time
EdDSA-keypair setup procedure.

## Acknowledgements

Carafe stands on the shoulders of years of work by other people:

- **[Wine](https://www.winehq.org)** — the actual Windows
  compatibility layer doing all the heavy lifting.
- **[Apple Game Porting Toolkit](https://developer.apple.com/games/game-porting-toolkit/)** —
  Apple's Wine + D3DMetal build that makes most of this possible on
  Apple Silicon.
- **[Gcenx / macOS_Wine_builds](https://github.com/Gcenx/macOS_Wine_builds)** —
  pre-built Wine Staging packages for Apple Silicon, used for
  Steam-compatible bottles.
- **[Winetricks](https://github.com/Winetricks/winetricks)** — the
  component installer (Visual C++, .NET, DXVK, the Steam-on-Wine
  workaround set, ...).
- **[SteamGridDB](https://www.steamgriddb.com)** — community-curated
  cover art.
- **[Sparkle](https://sparkle-project.org)** — the auto-update
  framework.

Carafe is not affiliated with or endorsed by any of the above
projects.

## License

MIT — see [LICENSE](LICENSE).
