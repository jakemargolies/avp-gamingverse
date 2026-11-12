import SwiftUI

struct LobbyView: View {
    static let windowID = "lobby"

    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @State private var botCount = 3

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Text("Gamingverse")
                    .font(.extraLargeTitle)
                Text("No-limit Texas Hold'em against computer opponents.")
                    .foregroundStyle(.secondary)
            }

            Stepper("Opponents: \(botCount)", value: $botCount, in: 1...HoldemTableModel.botNames.count)
                .frame(width: 300)

            VStack(spacing: 12) {
                Button("Enter Card Room", systemImage: "visionpro") {
                    Task { await enterCardRoom(newGame: true) }
                }
                .controlSize(.large)

                Button("Tabletop View") {
                    appModel.startNewGame(botCount: botCount)
                    openWindow(id: HoldemTableView.windowID)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(48)
        .onAppear {
            // Development shortcuts so a command-line launch can be screenshotted without tapping:
            // `xcrun simctl launch <device> <bundle id> -openTable` (volume) or `-openRoom` (immersive).
            let arguments = ProcessInfo.processInfo.arguments
            guard appModel.table == nil else { return }
            if arguments.contains("-openTable") {
                appModel.startNewGame(botCount: botCount)
                appModel.table?.dealNextHand()
                openWindow(id: HoldemTableView.windowID)
            } else if arguments.contains("-openRoom") {
                // The room deals once it's up, so the deal animates (add `-autopilot` to play your turns too).
                appModel.startNewGame(botCount: botCount)
                Task { await enterCardRoom(newGame: false) }
            }
        }
    }

    private func enterCardRoom(newGame: Bool) async {
        if newGame {
            appModel.startNewGame(botCount: botCount)
        }
        guard case .opened = await openImmersiveSpace(id: CardRoomView.spaceID) else { return }
        // The room replaces your surroundings, so put the flat windows away until you leave.
        dismissWindow(id: HoldemTableView.windowID)
        dismissWindow(id: LobbyView.windowID)
    }
}
