# avp-gamingverse
A multiplayer VR gaming experience for the Apple Vision Pro

## Layout

- `Packages/TabletopCore` — platform-independent game logic (cards, hand evaluation, no-limit Texas Hold'em engine, bots). No UI or RealityKit dependencies, so it can be tested on a Mac and later shared as the authoritative game state in multiplayer.

## Getting started

See **[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)** for Xcode setup, pairing a Vision Pro, and build/test/run instructions. Quick version:

```sh
cd Packages/TabletopCore
swift build
swift run holdem-sim [seed] [hands]   # bots play each other in the terminal
swift test                            # requires full Xcode, not just Command Line Tools
```

## Roadmap

1. Single player: Hold'em against bots at a virtual table in mixed reality (SwiftUI + RealityKit).
2. Multiplayer: SharePlay with Spatial Personas, bots replaced by remote players.
3. More games: other card and board games on the same table.
