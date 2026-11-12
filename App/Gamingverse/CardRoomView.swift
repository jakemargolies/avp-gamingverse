import RealityKit
import SwiftUI
import TabletopCore

/// Contents of the fully immersive card room.
struct CardRoomView: View {
    static let spaceID = "card-room"

    @Environment(AppModel.self) private var appModel

    var body: some View {
        if let table = appModel.table {
            CardRoomScene(table: table)
                .id(ObjectIdentifier(table)) // rebuild the scene for a new game
        }
    }
}

private struct CardRoomScene: View {
    let table: HoldemTableModel
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var props = RoomProps()

    var body: some View {
        RealityView { content, attachments in
            let world = Entity()
            content.add(world)
            world.addChild(CardRoomBuilder.makeRoom())
            world.addChild(CardRoomBuilder.makeTable())
            props.build(in: world, attachments: attachments, table: table)
            if ProcessInfo.processInfo.arguments.contains("-tiltRoom") {
                // Development aid: the simulator camera can't look down from the command line, so tip
                // the room up around your head to get the table into a screenshot.
                let head = SIMD3<Float>(0, 1.6, 0) // the simulator's camera height
                world.transform = Transform(matrix: Transform(translation: head).matrix
                    * Transform(rotation: simd_quatf(angle: 0.75, axis: [1, 0, 0])).matrix
                    * Transform(translation: -head).matrix)
            }
            props.update(table: table)
            props.animation = content.subscribe(to: SceneEvents.Update.self) { [props, table] event in
                MainActor.assumeIsolated {
                    props.animate(deltaTime: Float(event.deltaTime), table: table)
                }
            }
        } update: { _, _ in
            props.update(table: table)
        } attachments: {
            Attachment(id: "board") {
                BoardView(table: table)
            }
            Attachment(id: "controls") {
                VStack(spacing: 12) {
                    PlayerControlsView(table: table)
                    Button("Leave Card Room", systemImage: "door.left.hand.open") {
                        Task {
                            openWindow(id: LobbyView.windowID)
                            await dismissImmersiveSpace()
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .environment(appModel)
            }
            ForEach(table.botPlayers) { bot in
                Attachment(id: "cards-\(bot.id)") {
                    HoleCardsView(table: table, playerID: bot.id, cardWidth: 80, showsEmptySlots: false)
                }
                Attachment(id: "nameplate-\(bot.id)") {
                    PlayerInfoView(table: table, playerID: bot.id)
                        .padding(16)
                        .frame(width: 220)
                        .seatHighlight(table: table, playerID: bot.id)
                }
            }
        }
        .gesture(
            DragGesture()
                .targetedToEntity(props.controlsHandle)
                .onChanged { value in
                    guard let parent = props.controlsAnchor.parent else { return }
                    props.dragControls(to: value.convert(value.location3D, from: .local, to: parent))
                }
                .onEnded { _ in props.endControlsDrag() }
        )
    }
}

/// The parts of the room that follow the game: avatars, chips and the dealer button.
@MainActor
private final class RoomProps {
    var animation: EventSubscription?
    private var avatars: [PlayerID: AvatarRig] = [:]
    private var stacks: [PlayerID: ChipStack] = [:]
    private var seatAngles: [PlayerID: Float] = [:]
    private let pot = ChipStack(chipsPerDisc: 20, maxDiscs: 40)
    private let dealerButton = ModelEntity(
        mesh: .generateCylinder(height: 0.008, radius: 0.03),
        materials: [SimpleMaterial(color: .white, roughness: 0.4, isMetallic: false)]
    )
    private var time: Float = 0

    /// Holds your controls panel; drag `controlsHandle` to move it.
    let controlsAnchor = Entity()
    let controlsHandle = ModelEntity(
        mesh: .generateBox(size: [0.14, 0.012, 0.012], cornerRadius: 0.006),
        materials: [SimpleMaterial(color: UIColor(white: 0.85, alpha: 1), roughness: 0.3, isMetallic: false)]
    )
    private var dragOffset: SIMD3<Float>?

    private enum Focus {
        case ownCards, board, pot
        case player(PlayerID)
    }
    private var gazes: [PlayerID: (focus: Focus, until: Float)] = [:]
    private var seenEvents = 0
    private var seenHand = 0

    func build(in world: Entity, attachments: RealityViewAttachments, table: HoldemTableModel) {
        let tableTop = CardRoomLayout.tableHeight
        let center = CardRoomLayout.tableCenter

        if let board = attachments.entity(for: "board") {
            CardRoomLayout.fit(board, width: 0.62)
            board.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
            board.position = center + [0, tableTop + 0.002, 0.12]
            world.addChild(board)
        }
        if let controls = attachments.entity(for: "controls") {
            // Propped up like a tablet just over the near rail, low enough to see the board over when seated.
            controlsAnchor.position = [0, 0.84, -0.4]
            world.addChild(controlsAnchor)
            CardRoomLayout.fit(controls, width: 0.5)
            controls.orientation = simd_quatf(angle: -0.9, axis: [1, 0, 0])
            controlsAnchor.addChild(controls)

            // A grab bar along the bottom edge, like the one under a window.
            let bounds = controls.visualBounds(relativeTo: controlsAnchor)
            controlsHandle.position = [0, bounds.min.y - 0.015, bounds.max.z + 0.01]
            controlsHandle.components.set(InputTargetComponent())
            controlsHandle.components.set(CollisionComponent(shapes: [.generateBox(size: [0.22, 0.05, 0.05])]))
            controlsHandle.components.set(HoverEffectComponent())
            controlsAnchor.addChild(controlsHandle)
        }

        seatAngles[HoldemTableModel.humanID] = -.pi / 2
        let human = ChipStack(chipsPerDisc: 40)
        human.entity.position = CardRoomLayout.edgePoint(angle: -.pi / 2 + 0.35, inset: 0.15) + [0, tableTop, 0]
        stacks[HoldemTableModel.humanID] = human
        world.addChild(human.entity)

        let bots = table.botPlayers
        for (index, bot) in bots.enumerated() {
            let angle = CardRoomLayout.seatAngle(index: index, of: bots.count)
            seatAngles[bot.id] = angle

            let chairInset: Float = -0.42
            let avatar = AvatarRig(styleIndex: index, reach: -chairInset + 0.1)
            avatar.root.position = CardRoomLayout.edgePoint(angle: angle, inset: chairInset)
            avatar.root.orientation = CardRoomLayout.facing(from: avatar.root.position, to: center)
            avatars[bot.id] = avatar
            world.addChild(avatar.root)

            if let cards = attachments.entity(for: "cards-\(bot.id)") {
                CardRoomLayout.fit(cards, width: 0.15)
                let position = CardRoomLayout.edgePoint(angle: angle, inset: 0.2) + [0, tableTop + 0.002, 0]
                // Flat on the felt, reading the right way up from your seat.
                cards.orientation = CardRoomLayout.facing(from: position, to: CardRoomLayout.humanHead) * simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
                cards.position = position
                world.addChild(cards)
            }
            if let nameplate = attachments.entity(for: "nameplate-\(bot.id)") {
                CardRoomLayout.fit(nameplate, width: 0.3)
                let position = avatar.root.position + [0, 1.55, 0]
                nameplate.orientation = CardRoomLayout.facing(from: position, to: CardRoomLayout.humanHead)
                nameplate.position = position
                world.addChild(nameplate)
            }

            let stack = ChipStack(chipsPerDisc: 40)
            stack.entity.position = CardRoomLayout.edgePoint(angle: angle + 0.3, inset: 0.15) + [0, tableTop, 0]
            stacks[bot.id] = stack
            world.addChild(stack.entity)
        }

        pot.entity.position = center + [0, tableTop, -0.18]
        world.addChild(pot.entity)
        world.addChild(dealerButton)
    }

    func update(table: HoldemTableModel) {
        let game = table.game
        for player in game.players {
            stacks[player.id]?.update(chips: player.chips)
        }
        pot.update(chips: game.pot)

        if let dealer = game.dealerIndex.map({ game.players[$0].id }), let angle = seatAngles[dealer] {
            dealerButton.isEnabled = true
            dealerButton.position = CardRoomLayout.edgePoint(angle: angle - 0.3, inset: 0.18) + [0, CardRoomLayout.tableHeight + 0.004, 0]
        } else {
            dealerButton.isEnabled = false
        }
    }

    func dragControls(to point: SIMD3<Float>) {
        if dragOffset == nil {
            // Keep the panel where it is relative to the pinch, rather than jumping its center to the hand.
            dragOffset = controlsAnchor.position - point
        }
        controlsAnchor.position = point + dragOffset!
        // Keep the panel turned toward your seat wherever it's put.
        controlsAnchor.orientation = CardRoomLayout.facing(from: controlsAnchor.position, to: CardRoomLayout.humanHead)
    }

    func endControlsDrag() {
        dragOffset = nil
    }

    func animate(deltaTime: Float, table: HoldemTableModel) {
        time += deltaTime
        let game = table.game
        reactToNewEvents(in: game)

        for (id, avatar) in avatars {
            let player = game.player(id)!
            if gazes[id].map({ time >= $0.until }) ?? true {
                gazes[id] = (pickFocus(for: id, in: game), time + Float.random(in: 1.5...4))
            }
            avatar.animate(time: time, deltaTime: deltaTime, lookTarget: point(of: gazes[id]!.focus, for: id), isFolded: player.isInHand && player.hasFolded)
        }
    }

    /// Avatars sometimes glance at whoever just acted, and all look at new cards on the board.
    private func reactToNewEvents(in game: HoldemGame) {
        if game.handNumber != seenHand {
            seenHand = game.handNumber
            seenEvents = 0
        }
        for event in game.events.dropFirst(seenEvents) {
            switch event {
            case .acted(let actor, _):
                for id in avatars.keys where id != actor && Bool.random() {
                    gazes[id] = (.player(actor), time + Float.random(in: 0.8...1.6))
                }
            case .communityDealt:
                for id in avatars.keys {
                    gazes[id] = (.board, time + Float.random(in: 1.5...2.5))
                }
            default:
                break
            }
        }
        seenEvents = game.events.count
    }

    /// Mostly the table, sometimes whoever is acting; you only get the occasional glance.
    private func pickFocus(for id: PlayerID, in game: HoldemGame) -> Focus {
        if game.currentPlayer?.id == id {
            return Double.random(in: 0..<1) < 0.75 ? .ownCards : .board
        }
        let roll = Double.random(in: 0..<1)
        if let current = game.currentPlayer?.id {
            let lookAtActor = current == HoldemTableModel.humanID ? 0.12 : 0.3
            if roll < lookAtActor { return .player(current) }
        }
        if roll < 0.55 { return .board }
        if roll < 0.7 { return .pot }
        return .ownCards
    }

    private func point(of focus: Focus, for id: PlayerID) -> SIMD3<Float> {
        let tableTop = SIMD3<Float>(0, CardRoomLayout.tableHeight, 0)
        switch focus {
        case .ownCards:
            return CardRoomLayout.edgePoint(angle: seatAngles[id] ?? .pi / 2, inset: 0.2) + tableTop
        case .board:
            return CardRoomLayout.tableCenter + tableTop + [0, 0, 0.12]
        case .pot:
            return CardRoomLayout.tableCenter + tableTop + [0, 0, -0.18]
        case .player(let other):
            if other == HoldemTableModel.humanID { return CardRoomLayout.humanHead }
            return avatars[other]?.headPosition ?? CardRoomLayout.tableCenter + tableTop
        }
    }
}
