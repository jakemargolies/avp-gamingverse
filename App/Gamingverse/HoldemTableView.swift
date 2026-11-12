import RealityKit
import SwiftUI
import TabletopCore

/// Contents of the volumetric table window.
struct HoldemTableView: View {
    static let windowID = "holdem-table"

    @Environment(AppModel.self) private var appModel

    var body: some View {
        if let table = appModel.table {
            TableScene(table: table)
                .id(ObjectIdentifier(table)) // rebuild the scene for a new game
        } else {
            Text("Start a game from the main window.")
                .font(.title)
                .padding(40)
                .glassBackgroundEffect()
        }
    }
}

private struct TableScene: View {
    let table: HoldemTableModel

    var body: some View {
        RealityView { content, attachments in
            let root = Entity()
            content.add(root)
            root.addChild(TableLayout.makeTable())

            if let board = attachments.entity(for: "board") {
                root.addChild(board)
                // Mostly flat on the felt, tipped up a little toward you.
                board.orientation = simd_quatf(angle: -.pi * 0.4, axis: [1, 0, 0])
                board.scale = .init(repeating: 1.5)
                TableLayout.rest(board, at: [0, 0, 0.12])
            }
            let bots = table.botPlayers
            for (index, bot) in bots.enumerated() {
                guard let seat = attachments.entity(for: bot.id) else { continue }
                root.addChild(seat)
                seat.scale = .init(repeating: 1.5)
                TableLayout.rest(seat, at: TableLayout.seatPosition(index: index, of: bots.count))
            }
        } attachments: {
            Attachment(id: "board") {
                BoardView(table: table)
            }
            ForEach(table.botPlayers) { bot in
                Attachment(id: bot.id) {
                    SeatView(table: table, playerID: bot.id)
                }
            }
        }
        .ornament(attachmentAnchor: .scene(.bottomFront)) {
            PlayerControlsView(table: table)
        }
    }
}

enum TableLayout {
    static let volumeSize: SIMD3<Double> = [1.2, 0.6, 1.0]
    /// Height of the felt; the volume's origin is at its center, so this is just above the floor of the volume.
    static let tableTop: Float = -Float(volumeSize.y) / 2 + 0.12
    static let radiusX: Float = 0.5
    static let radiusZ: Float = 0.32

    /// Bots sit around the far side of the table in dealing (clockwise) order, starting on your left.
    static func seatPosition(index: Int, of count: Int) -> SIMD3<Float> {
        let angle = Float.pi * (Float(index) + 0.5) / Float(count)
        return [-radiusX * 0.85 * cos(angle), 0, -radiusZ * 0.85 * sin(angle)]
    }

    /// Places `entity` at `position` with its lowest point resting on the felt.
    static func rest(_ entity: Entity, at position: SIMD3<Float>) {
        entity.position = position
        let bounds = entity.visualBounds(relativeTo: entity.parent)
        entity.position.y += tableTop - bounds.min.y
    }

    static func makeTable() -> Entity {
        let table = Entity()

        let felt = ModelEntity(
            mesh: .generateCylinder(height: 0.02, radius: 1),
            materials: [SimpleMaterial(color: UIColor(red: 0.05, green: 0.38, blue: 0.2, alpha: 1), roughness: 0.95, isMetallic: false)]
        )
        felt.scale = [radiusX, 1, radiusZ]
        felt.position.y = tableTop - 0.01
        table.addChild(felt)

        let rail = ModelEntity(
            mesh: .generateCylinder(height: 0.03, radius: 1),
            materials: [SimpleMaterial(color: UIColor(red: 0.3, green: 0.16, blue: 0.08, alpha: 1), roughness: 0.4, isMetallic: false)]
        )
        rail.scale = [radiusX + 0.04, 1, radiusZ + 0.04]
        rail.position.y = tableTop - 0.017
        table.addChild(rail)

        let floor = -Float(volumeSize.y) / 2
        let pedestal = ModelEntity(
            mesh: .generateCylinder(height: tableTop - floor, radius: 0.06),
            materials: [SimpleMaterial(color: .darkGray, roughness: 0.5, isMetallic: true)]
        )
        pedestal.position.y = (tableTop + floor) / 2
        table.addChild(pedestal)

        return table
    }
}
