# AGENTS.md

This file provides guidance to coding agents when working with code in this repository.

# Leader Key Development Guide

## Build & Test Commands

- Build and run: `xcodebuild -scheme "Leader Key" -configuration Debug build`
- Run all tests: `xcodebuild -scheme "Leader Key" -testPlan "TestPlan" test`
- Run single test: `xcodebuild -scheme "Leader Key" -testPlan "TestPlan" -only-testing:Leader KeyTests/UserConfigTests/testInitializesWithDefaults test`
- Bump version: `bin/bump`
- Create release: `bin/release`

## machine-spirit fork — build, sign, redeploy (READ THIS)

This fork is the **daily-driver launcher** (LaunchAgent `com.machinespirit.leader-key`,
runs from `~/Applications/MachineSpirit Leader Key.app`). Two rules differ from upstream:

1. **Always re-sign with the stable local cert after building.** Builds are ad-hoc,
   and ad-hoc signatures change every build — which RESETS the app's TCC grants
   (Screen Recording for the `ss-*` screenshot binds, Accessibility for app control)
   and traps the owner in a grant→re-prompt loop. `install.sh` creates the
   per-machine cert if absent; after any manual build, re-sign:
   `codesign --force --deep -s "MachineSpirit Local Codesign" "$HOME/Applications/MachineSpirit Leader Key.app"`
2. **Asset-catalog changes need `clean build`.** xcodebuild caches `Assets.car` on
   incremental builds, so a changed menu-bar or app icon won't take effect otherwise.

Full Release build + redeploy recipe this repo uses:
```
cd forks/LeaderKey
xcodebuild -project "Leader Key.xcodeproj" -scheme "Leader Key" -configuration Release \
  -derivedDataPath ./DerivedData-Release -skipPackagePluginValidation -skipMacroValidation \
  clean build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
launchctl bootout "gui/$(id -u)/com.machinespirit.leader-key" 2>/dev/null
rm -rf "$HOME/Applications/MachineSpirit Leader Key.app"
ditto "DerivedData-Release/Build/Products/Release/Leader Key.app" "$HOME/Applications/MachineSpirit Leader Key.app"
codesign --force --deep -s "MachineSpirit Local Codesign" "$HOME/Applications/MachineSpirit Leader Key.app"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.machinespirit.leader-key.plist"
```
Menu-bar icon assets: `Leader Key/Assets.xcassets/StatusItem*.imageset` (idle = template
skull; `StatusItem-filled` = green non-template summon glow). App icon:
`AppIcon.appiconset` — the summoned green skull on a dark squircle, regenerated from the
menu-bar mark by `tools/make-appicon.sh` (ImageMagick + `qlmanage`; PNGs ship pre-rendered).
Re-run it if the skull mark or palette changes, then `clean build`.

## Architecture Overview

Leader Key is a macOS application that provides customizable keyboard shortcuts. The core architecture consists of:

**Key Components:**

- `AppDelegate`: Application lifecycle, global shortcuts registration, update management
- `Controller`: Central event handling, manages key sequences and window display
- `UserConfig`: JSON configuration management with validation
- `UserState`: Tracks navigation through key sequences
- `MainWindow`: Base class for theme windows

**Theme System:**

- Themes inherit from `MainWindow` and implement `draw()` method
- Available themes: MysteryBox, Mini, Breadcrumbs, ForTheHorde, Cheater
- Each theme provides different visual representations of shortcuts

**Configuration Flow:**

- Config stored at `~/Library/Application Support/Leader Key/config.json`
- `FileMonitor` watches for changes and triggers reload
- `ConfigValidator` ensures no key conflicts
- Actions support: applications, URLs, commands, folders

**Testing Architecture:**

- Uses XCTest with custom `TestAlertManager` for UI testing
- Tests use isolated UserDefaults and temporary directories
- Focus on configuration validation and state management

## Code Style Guidelines

- **Imports**: Group Foundation/AppKit imports first, then third-party libraries (Combine, Defaults)
- **Naming**: Use descriptive camelCase for variables/functions, PascalCase for types
- **Types**: Use explicit type annotations for public properties and parameters
- **Error Handling**: Use appropriate error handling with do/catch blocks and alerts
- **Extensions**: Create extensions for additional functionality on existing types
- **State Management**: Use @Published and ObservableObject for reactive UI updates
- **Testing**: Create separate test cases with descriptive names, use XCTAssert\* methods
- **Access Control**: Use appropriate access modifiers (private, fileprivate, internal)
- **Documentation**: Use comments for complex logic or non-obvious implementations

Follow Swift idioms and default formatting (4-space indentation, spaces around operators).

