import SwiftUI

@main
struct GamingverseApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            LobbyView()
                .environment(appModel)
        }
        .windowResizability(.contentSize)

        WindowGroup(id: HoldemTableView.windowID) {
            HoldemTableView()
                .environment(appModel)
        }
        .windowStyle(.volumetric)
        .defaultSize(width: TableLayout.volumeSize.x, height: TableLayout.volumeSize.y, depth: TableLayout.volumeSize.z, in: .meters)
        .defaultWindowPlacement { _, context in
            // Open beside the lobby rather than on top of it.
            if let lobby = context.windows.first {
                return WindowPlacement(.trailing(lobby))
            }
            return WindowPlacement()
        }
    }
}

@MainActor @Observable
final class AppModel {
    /// The game being played, if one has been started from the lobby.
    private(set) var table: HoldemTableModel?

    func startNewGame(botCount: Int) {
        table = HoldemTableModel(botCount: botCount)
    }
}
