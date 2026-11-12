# Development Guide

How to set up a Mac to build avp-gamingverse, run the game logic locally, and deploy to an Apple Vision Pro.

## Prerequisites

| Requirement | Notes |
| --- | --- |
| Mac with Apple silicon | Required for the visionOS simulator. |
| Xcode (latest from the Mac App Store) | The Command Line Tools alone are not enough: they can build `TabletopCore` but cannot run tests or build visionOS apps. |
| visionOS platform for Xcode | Installed from inside Xcode (see below). |
| Apple ID | A free account can deploy to your own devices; builds expire after 7 days. A paid Apple Developer Program membership is needed for longer-lived builds, TestFlight and SharePlay entitlements. |
| Apple Vision Pro (optional) | You can work in the simulator until you need hand tracking and real-room placement. |

## 1. Install and select Xcode

1. Install **Xcode** from the Mac App Store and open it once to accept the license and install components.
2. When asked which platforms to install, include **visionOS**. If you skipped it, go to **Xcode → Settings → Components** and install the visionOS platform and simulator.
3. Point the command-line tools at Xcode rather than the standalone Command Line Tools:

   ```sh
   sudo xcode-select -s /Applications/Xcode.app
   xcodebuild -version              # should print the Xcode version
   xcrun simctl list runtimes       # should list a visionOS runtime
   ```

4. Sign in with your Apple ID under **Xcode → Settings → Accounts** so Xcode can create a signing team.

## 2. Build and test the game logic

All game rules live in `Packages/TabletopCore`, a Swift package with no UI dependencies. It builds and runs on macOS, so most logic work doesn't need the headset.

```sh
cd Packages/TabletopCore

swift build                       # compile the library and the simulator
swift test                        # run unit tests (needs Xcode selected, step 1)
swift run holdem-sim              # bots play 50 hands in the terminal
swift run holdem-sim 7 200        # same, with seed 7 and up to 200 hands
```

`holdem-sim` prints each hand (blinds, hole cards, actions, board, showdown) and stops if chips are ever created or lost, which makes it a handy smoke test after changing the engine. The same seed always produces the same game.

You can also open `Packages/TabletopCore/Package.swift` in Xcode and run the tests with **⌘U**.

## 3. Pair an Apple Vision Pro

Do this once per Mac/headset pair.

1. Put the Mac and the Vision Pro on the same Wi-Fi network.
2. On the Vision Pro, open **Settings → General → Remote Devices**. It will show a pairing code.
3. On the Mac, open **Device Hub** in Xcode with **⇧⌘2** (Xcode 27 replaced the old *Window → Devices and Simulators*, which no longer appears in the Window menu). Select the Vision Pro and pair it, entering the code shown in the headset.
4. On the Vision Pro, open **Settings → Privacy & Security → Developer Mode**, turn it on, and restart when prompted. (The Developer Mode option only appears after the device has been paired with Xcode.)

Each headset you want to test multiplayer with needs to be paired and have Developer Mode on.

## 4. Build and run the Vision Pro app

The Xcode project is generated from `project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen), so `Gamingverse.xcodeproj` is not committed. Change build settings, targets and dependencies in `project.yml`, not in Xcode: edits made in Xcode's project editor are lost the next time the project is generated.

```sh
brew install xcodegen        # once
xcodegen                     # from the repo root; rerun after pulling or after adding/removing files
open Gamingverse.xcodeproj
```

1. Pick a run destination: **Apple Vision Pro** (simulator) or your paired headset.
2. For a real headset, the signing team comes from `DEVELOPMENT_TEAM` in `project.yml`. To use a different team, change it there (the ID is shown next to the team in **Xcode → Settings → Accounts**) and rerun `xcodegen`.
3. Press **⌘R**. The lobby window opens; choose the number of opponents and press **Enter Card Room** (fully immersive, life-size table; best played seated) or **Tabletop View** (a small table in a volume in your room).

From the command line (the simulator must be booted, e.g. by opening Simulator.app):

```sh
xcodebuild -project Gamingverse.xcodeproj -scheme Gamingverse \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' \
  -derivedDataPath .build/DerivedData build
xcrun simctl install booted .build/DerivedData/Build/Products/Debug-xrsimulator/Gamingverse.app
xcrun simctl launch booted com.jakemargolies.gamingverse -openTable
xcrun simctl io booted screenshot screenshot.png
```

`-openTable` is a development shortcut that opens the table and deals the first hand straight away, so the table can be checked without clicking through the lobby. `-openRoom` does the same for the immersive card room; add `-tiltRoom` to tip the room toward the simulator's level camera so the table is in the screenshot. Add `-autopilot` to have your turns checked or called automatically so whole hands play out unattended.

### Simulator vs. device

The simulator is fine for layout, game flow and UI. Use a real headset for anything involving hand tracking, how things look at real scale, or performance. In the simulator, drag to look around and click to "tap".

## Troubleshooting

- **`xcodebuild requires Xcode, but active developer directory ... is a command line tools instance`**: run the `xcode-select` command from step 1.
- **`XCTest not available` when running `swift test`**: same cause; select Xcode.
- **Vision Pro doesn't appear in Device Hub**: check that both are on the same network, the headset is unlocked and worn (or awake), and **Remote Devices** is open on the headset.
- **App stops launching on the headset after a week**: free-account provisioning profiles expire after 7 days; rebuild from Xcode to renew.
