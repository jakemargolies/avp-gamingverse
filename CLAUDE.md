# avp-gamingverse

Multiplayer tabletop games for Apple Vision Pro. See `README.md` for the layout and roadmap and `docs/DEVELOPMENT.md` for full setup.

## Commands

- Game logic: `cd Packages/TabletopCore && swift build && swift test`; `swift run holdem-sim [seed] [hands]` smoke-tests the engine.
- App project: `xcodegen` at the repo root regenerates `Gamingverse.xcodeproj` from `project.yml` (the project file is not committed; never edit it directly).
- App build: `xcodebuild -project Gamingverse.xcodeproj -scheme Gamingverse -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -derivedDataPath .build/DerivedData build`
- Visual check: install the built app with `xcrun simctl install booted <app>`, launch with `xcrun simctl launch booted com.jakemargolies.gamingverse -openTable` (opens the table and deals), then `xcrun simctl io booted screenshot <file>`.

## Conventions

- Game rules live in `TabletopCore` and stay free of UI/RealityKit imports so they can run on macOS and later act as shared multiplayer state. The app only renders state and forwards actions.
- Swift 6 language mode; UI models are `@MainActor @Observable`.
- SourceKit errors like "Cannot find X in scope" in the editor are usually indexing noise; trust `xcodebuild`.
