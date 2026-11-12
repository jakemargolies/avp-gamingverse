import SwiftUI

struct LobbyView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
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

            Button(appModel.table == nil ? "Open Table" : "Start New Game") {
                appModel.startNewGame(botCount: botCount)
                openWindow(id: HoldemTableView.windowID)
            }
            .controlSize(.large)
        }
        .padding(48)
        .onAppear {
            // Development shortcut: `-openTable` opens the table and deals, so a launch from the
            // command line (`xcrun simctl launch <device> <bundle id> -openTable`) can be screenshotted without tapping.
            guard ProcessInfo.processInfo.arguments.contains("-openTable"), appModel.table == nil else { return }
            appModel.startNewGame(botCount: botCount)
            appModel.table?.dealNextHand()
            openWindow(id: HoldemTableView.windowID)
        }
    }
}
