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
    @State private var director = TableDirector()

    var body: some View {
        RealityView { content, attachments in
            let world = Entity()
            content.add(world)
            world.addChild(CardRoomBuilder.makeRoom())
            world.addChild(CardRoomBuilder.makeTable())
            await director.build(in: world, attachments: attachments, table: table)

            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-tiltRoom") {
                // Development aid: the simulator camera can't look down from the command line, so tip
                // the room up around your head to get the table into a screenshot.
                let head = SIMD3<Float>(0, 1.6, 0) // the simulator's camera height
                world.transform = Transform(matrix: Transform(translation: head).matrix
                    * Transform(rotation: simd_quatf(angle: 0.75, axis: [1, 0, 0])).matrix
                    * Transform(translation: -head).matrix)
            }

            director.animation = content.subscribe(to: SceneEvents.Update.self) { [director, table] event in
                MainActor.assumeIsolated {
                    director.step(deltaTime: Float(event.deltaTime), table: table)
                }
            }
            table.presenter = director

            if arguments.contains("-openRoom"), table.game.handNumber == 0 {
                // Development aid: deal once the room is up so the opening animations play.
                table.autopilot = arguments.contains("-autopilot")
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    table.dealNextHand()
                }
            }
        } update: { _, _ in
        } attachments: {
            Attachment(id: "board") {
                BoardView(table: table, showsCards: false, showsPot: false)
            }
            Attachment(id: "pot") {
                Text(table.game.pot > 0 ? "Pot \(table.game.pot)" : "")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .padding(.horizontal, 20)
                    .frame(width: 320)
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
                .targetedToEntity(director.controlsHandle)
                .onChanged { value in
                    guard let parent = director.controlsAnchor.parent else { return }
                    director.dragControls(to: value.convert(value.location3D, from: .local, to: parent))
                }
                .onEnded { _ in director.endControlsDrag() }
        )
        .onDisappear {
            director.tearDown()
            if table.presenter === director {
                table.presenter = nil
            }
        }
    }
}

/// Everything in the room that follows the game. Plays each game event as an animation (cards
/// dealt from the shoe, chips flying, flips, celebrations) and keeps the avatars alive between them.
@MainActor
private final class TableDirector: GamePresenter {
    var animation: EventSubscription?
    let animator = Animator()
    private let sounds = SoundBank()
    private var world = Entity()
    private var textures: CardTextures?
    private var lamp: Entity?

    // Seats
    private var seatAngles: [PlayerID: Float] = [:]
    private var avatars: [PlayerID: AvatarRig] = [:]

    // Cards
    private var holeCards: [PlayerID: [CardEntity]] = [:]
    private var boardCards: [CardEntity] = []
    private let shoe = Entity()
    private static let holeCardWidth: Float = 0.075
    private static let boardCardWidth: Float = 0.095
    private static let boardPitch: Float = 0.116

    // Chips. The counts are the director's own replay of the betting, so stacks can change at the
    // moment chips land rather than when the engine moved them.
    private var stacks: [PlayerID: ChipStack] = [:]
    private var bets: [PlayerID: ChipStack] = [:]
    private let pot = ChipStack(chipsPerDisc: 20, maxDiscs: 40)
    private var stackChips: [PlayerID: Int] = [:]
    private var betChips: [PlayerID: Int] = [:]
    private var potChips = 0
    private let chipMesh = MeshResource.generateCylinder(height: ChipStack.discHeight * 0.9, radius: 0.02)
    private lazy var chipMaterials = ChipStack.colors.map { SimpleMaterial(color: $0, roughness: 0.5, isMetallic: false) }

    // Markers
    private let dealerButton = ModelEntity(
        mesh: .generateCylinder(height: 0.008, radius: 0.03),
        materials: [SimpleMaterial(color: .white, roughness: 0.4, isMetallic: false)]
    )
    private let turnRing = ModelEntity(mesh: .generatePlane(width: 0.34, depth: 0.34))
    private var ringTarget: SIMD3<Float>?
    private var lastTurn: PlayerID?
    private var banner: Entity?

    // Avatar behavior
    private enum Focus {
        case ownCards, board, pot
        case player(PlayerID)
    }
    private var gazes: [PlayerID: (focus: Focus, until: Float)] = [:]
    private var celebrateUntil: [PlayerID: Float] = [:]
    private var pushUntil: [PlayerID: Float] = [:]

    // Controls panel
    let controlsAnchor = Entity()
    let controlsHandle = ModelEntity(
        mesh: .generateBox(size: [0.14, 0.012, 0.012], cornerRadius: 0.006),
        materials: [SimpleMaterial(color: UIColor(white: 0.85, alpha: 1), roughness: 0.3, isMetallic: false)]
    )
    private var dragOffset: SIMD3<Float>?

    private var time: Float { animator.time }
    private static let tableTop = SIMD3<Float>(0, CardRoomLayout.tableHeight, 0)
    private static let human = HoldemTableModel.humanID

    // MARK: - Setup

    func build(in world: Entity, attachments: RealityViewAttachments, table: HoldemTableModel) async {
        self.world = world
        let textures = await CardTextures.load()
        self.textures = textures
        lamp = world.findEntity(named: CardRoomBuilder.lampLightName)
        let center = CardRoomLayout.tableCenter

        if let board = attachments.entity(for: "board") {
            CardRoomLayout.fit(board, width: Self.boardPitch * 480 / 90) // slot pitch is 90 of the view's 480 points
            board.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
            board.position = center + Self.tableTop + [0, 0.001, 0.09]
            world.addChild(board)
        }
        if let label = attachments.entity(for: "pot") {
            CardRoomLayout.fit(label, width: 0.22)
            label.position = potSpot + [0, 0.2, 0]
            label.orientation = CardRoomLayout.facing(from: label.position, to: CardRoomLayout.humanHead)
            world.addChild(label)
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

        seatAngles[Self.human] = -.pi / 2
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

            if let nameplate = attachments.entity(for: "nameplate-\(bot.id)") {
                CardRoomLayout.fit(nameplate, width: 0.3)
                let position = avatar.root.position + [0, 1.55, 0]
                nameplate.orientation = CardRoomLayout.facing(from: position, to: CardRoomLayout.humanHead)
                nameplate.position = position
                world.addChild(nameplate)
            }
        }

        for player in table.game.players {
            let stack = ChipStack(chipsPerDisc: 40)
            stack.entity.position = stackSpot(player.id)
            stacks[player.id] = stack
            world.addChild(stack.entity)
            let bet = ChipStack(chipsPerDisc: 10, maxDiscs: 20)
            bet.entity.position = betSpot(player.id)
            bets[player.id] = bet
            world.addChild(bet.entity)
        }
        pot.entity.position = potSpot
        world.addChild(pot.entity)

        // The shoe the cards are dealt from.
        shoe.position = shoeSpot
        shoe.orientation = CardRoomLayout.facing(from: shoeSpot, to: CardRoomLayout.humanHead)
        let box = CardRoomBuilder.box([0.1, 0.05, 0.135], color: UIColor(red: 0.2, green: 0.1, blue: 0.06, alpha: 1), roughness: 0.4, cornerRadius: 0.008)
        box.position.y = 0.025
        shoe.addChild(box)
        let topCard = CardEntity(Card.fullDeck[0], textures: textures, width: Self.holeCardWidth)
        topCard.entity.position.y = 0.051
        shoe.addChild(topCard.entity)
        world.addChild(shoe)

        world.addChild(dealerButton)
        turnRing.model?.materials = [textures.turnRing]
        turnRing.components.set(OpacityComponent(opacity: 0))
        world.addChild(turnRing)

        sync(to: table.game)
    }

    func tearDown() {
        animator.stop()
        animation?.cancel()
        animation = nil
    }

    /// Lays out the current state with no animation, e.g. when entering mid-game.
    private func sync(to game: HoldemGame) {
        guard let textures else { return }
        for card in holeCards.values.flatMap({ $0 }) + boardCards {
            card.entity.removeFromParent()
        }
        holeCards = [:]
        boardCards = []
        for player in game.players where player.isLive {
            let faceUp = player.id == Self.human || game.phase == .handComplete
            holeCards[player.id] = player.holeCards.enumerated().map { index, card in
                let entity = CardEntity(card, textures: textures, width: Self.holeCardWidth, faceUp: faceUp)
                place(entity, at: holeSpot(player.id, index))
                world.addChild(entity.entity)
                return entity
            }
        }
        for (index, card) in game.community.enumerated() {
            let entity = CardEntity(card, textures: textures, width: Self.boardCardWidth, faceUp: true)
            place(entity, at: boardSpot(index))
            world.addChild(entity.entity)
            boardCards.append(entity)
        }
        settle(game)
        if let dealer = game.dealerIndex.map({ game.players[$0].id }) {
            dealerButton.position = dealerSpot(dealer)
        }
        dealerButton.isEnabled = game.dealerIndex != nil
    }

    /// Snaps chip stacks to the engine's numbers once a batch of events has played.
    private func settle(_ game: HoldemGame) {
        for player in game.players {
            stackChips[player.id] = player.chips
            betChips[player.id] = player.streetBet
        }
        potChips = game.pot - game.players.reduce(0) { $0 + $1.streetBet }
        refreshChips()
    }

    private func refreshChips() {
        for (id, stack) in stacks { stack.update(chips: stackChips[id] ?? 0) }
        for (id, bet) in bets { bet.update(chips: betChips[id] ?? 0) }
        pot.update(chips: potChips)
    }

    // MARK: - Layout

    private var potSpot: SIMD3<Float> { CardRoomLayout.tableCenter + Self.tableTop + [0, 0, -0.1] }
    private var shoeSpot: SIMD3<Float> { CardRoomLayout.tableCenter + Self.tableTop + [0.32, 0, -0.12] }

    private func angle(of id: PlayerID) -> Float { seatAngles[id] ?? -.pi / 2 }

    /// Hole cards sit in front of each bot, and to the right of your controls for you; all of them
    /// read the right way up from your seat.
    private func holeSpot(_ id: PlayerID, _ index: Int) -> (position: SIMD3<Float>, orientation: simd_quatf) {
        let middle = CardRoomLayout.edgePoint(angle: id == Self.human ? -.pi / 2 - 0.3 : angle(of: id), inset: 0.2) + Self.tableTop
        let heading = CardRoomLayout.facing(from: middle, to: CardRoomLayout.humanHead)
        let offset = heading.act([index == 0 ? -0.042 : 0.042, 0.0015 * Float(index), 0])
        return (middle + offset, heading)
    }

    private func boardSpot(_ index: Int) -> (position: SIMD3<Float>, orientation: simd_quatf) {
        (CardRoomLayout.tableCenter + Self.tableTop + [Float(index - 2) * Self.boardPitch, 0.002, 0.09], simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
    }

    private func betSpot(_ id: PlayerID) -> SIMD3<Float> {
        CardRoomLayout.edgePoint(angle: angle(of: id), inset: id == Self.human ? 0.3 : 0.36) + Self.tableTop
    }

    private func stackSpot(_ id: PlayerID) -> SIMD3<Float> {
        CardRoomLayout.edgePoint(angle: angle(of: id) + 0.35, inset: 0.15) + Self.tableTop
    }

    private func dealerSpot(_ id: PlayerID) -> SIMD3<Float> {
        let offset: Float = id == Self.human ? -0.65 : -0.3
        return CardRoomLayout.edgePoint(angle: angle(of: id) + offset, inset: 0.17) + Self.tableTop + [0, 0.004, 0]
    }

    /// Just above a player's head for bots; over your bet for you.
    private func calloutSpot(_ id: PlayerID) -> SIMD3<Float> {
        if let avatar = avatars[id] {
            let toward = normalize(CardRoomLayout.tableCenter - avatar.root.position) * 0.15
            return avatar.root.position + toward + [0, 1.4, 0]
        }
        return betSpot(id) + [0, 0.14, 0]
    }

    private func place(_ card: CardEntity, at spot: (position: SIMD3<Float>, orientation: simd_quatf)) {
        card.entity.position = spot.position
        card.entity.orientation = spot.orientation
    }

    private var allCards: [CardEntity] { holeCards.values.flatMap { $0 } + boardCards }

    // MARK: - Presenting events

    func present(_ events: [GameEvent], from before: HoldemGame, to after: HoldemGame) async {
        for event in events {
            switch event {
            case .handStarted(_, let dealer):
                await startHand(dealer: dealer, in: after)
            case .blindPosted(let id, let amount):
                await bet(amount, by: id)
            case .holeCardsDealt:
                await dealHoleCards(in: after)
            case .acted(let id, let action):
                await present(action, by: id, in: after)
            case .communityDealt(let street, let cards):
                await dealBoard(street, cards)
            case .uncalledBetReturned(let id, let amount):
                await returnBet(amount, to: id)
            case .showdown(let hands):
                await showdown(hands, in: after)
            case .potAwarded(let amount, let winners):
                await award(amount, to: winners, in: after)
            }
        }
        settle(after)
    }

    private func startHand(dealer: PlayerID, in game: HoldemGame) async {
        if let banner {
            animator.fade(banner, to: 0, duration: 0.3)
            animator.run(duration: 0, delay: 0.3) { _ in banner.removeFromParent() }
            self.banner = nil
        }
        // Sweep last hand's cards back into the shoe.
        let leftovers = allCards
        if !leftovers.isEmpty {
            sounds.play(.swish, from: shoe)
            for (index, card) in leftovers.enumerated() {
                animator.launch(card.entity, to: shoeSpot + [0, 0.06, 0], arc: 0.08, duration: 0.45, delay: Float(index) * 0.02)
                animator.fade(card.entity, to: 0, duration: 0.2, delay: 0.3 + Float(index) * 0.02)
            }
            await animator.wait(0.5 + Float(leftovers.count) * 0.02)
            leftovers.forEach { $0.entity.removeFromParent() }
        }
        holeCards = [:]
        boardCards = []

        for player in game.players {
            stackChips[player.id] = player.chips + player.handCommitted
            betChips[player.id] = 0
        }
        potChips = 0
        refreshChips()

        dealerButton.isEnabled = true
        sounds.play(.chipClack, from: dealerButton)
        await animator.fly(dealerButton, to: dealerSpot(dealer), arc: 0.08, duration: 0.5)
    }

    private func dealHoleCards(in game: HoldemGame) async {
        guard let textures, let dealer = game.dealerIndex else { return }
        let seats = (1...game.players.count).map { game.players[(dealer + $0) % game.players.count] }.filter(\.isInHand)
        var delay: Float = 0
        for round in 0..<2 {
            for player in seats {
                let card = CardEntity(player.holeCards[round], textures: textures, width: Self.holeCardWidth)
                card.entity.position = shoeSpot + [0, 0.06, 0]
                card.entity.orientation = shoe.orientation
                world.addChild(card.entity)
                holeCards[player.id, default: []].append(card)
                let spot = holeSpot(player.id, round)
                animator.launch(card.entity, to: spot.position, orientation: spot.orientation, arc: 0.12, spins: 1, duration: 0.38, delay: delay)
                animator.run(duration: 0, delay: delay) { [sounds, shoe] _ in sounds.play(.cardFlick, from: shoe) }
                delay += 0.1
            }
        }
        await animator.wait(delay + 0.3)

        // Peek at your own cards.
        for (index, card) in (holeCards[Self.human] ?? []).enumerated() {
            animator.run(duration: 0, delay: Float(index) * 0.15) { [sounds] _ in sounds.play(.cardFlip, from: card.entity) }
            await card.flip(using: animator, lift: 0.06, duration: 0.35, delay: Float(index) * 0.15)
        }
    }

    private func present(_ action: PlayerAction, by id: PlayerID, in game: HoldemGame) async {
        for other in avatars.keys where other != id && Bool.random() {
            gazes[other] = (.player(id), time + Float.random(in: 0.8...1.6))
        }
        let currentBet = betChips.values.max() ?? 0
        let stack = stackChips[id] ?? 0

        switch action {
        case .fold:
            callout("Fold", for: id, color: UIColor(white: 0.75, alpha: 1))
            await muck(id)
        case .check:
            callout("Check", for: id, color: .white)
            avatars[id]?.tap(at: time)
            sounds.play(.knock, from: avatars[id]?.root ?? controlsAnchor)
            await animator.wait(0.4)
        case .call:
            let amount = min(currentBet - (betChips[id] ?? 0), stack)
            if amount >= stack {
                await allIn(amount, by: id)
            } else {
                callout("Call \(amount)", for: id, color: UIColor(red: 0.6, green: 0.85, blue: 1, alpha: 1))
                pushUntil[id] = time + 0.5
                await bet(amount, by: id)
            }
        case .raise(let to):
            let amount = to - (betChips[id] ?? 0)
            if amount >= stack {
                await allIn(amount, by: id)
            } else {
                callout(currentBet == 0 ? "Bet \(to)" : "Raise to \(to)", for: id, color: UIColor(red: 1, green: 0.75, blue: 0.3, alpha: 1))
                pushUntil[id] = time + 0.7
                await bet(amount, by: id, discs: 6)
            }
        }
    }

    private func allIn(_ amount: Int, by id: PlayerID) async {
        callout("ALL IN!", for: id, color: UIColor(red: 1, green: 0.25, blue: 0.2, alpha: 1), height: 0.075, hold: 1.6, evenForYou: true)
        sounds.play(.boom, from: world, gain: -2)
        lampPulse(to: UIColor(red: 1, green: 0.25, blue: 0.15, alpha: 1), intensity: 0.55, attack: 0.25, hold: 1.0, release: 0.9)
        pushUntil[id] = time + 1.4
        for other in avatars.keys where other != id {
            gazes[other] = (.player(id), time + 2)
        }
        await animator.wait(0.3)
        await bet(amount, by: id, discs: 14, stagger: 0.03)
        sounds.play(.chipShower, from: bets[id]!.entity)
        await animator.wait(0.5)
    }

    private func muck(_ id: PlayerID) async {
        let cards = holeCards[id] ?? []
        holeCards[id] = nil
        guard let first = cards.first else { return }
        sounds.play(.swish, from: first.entity)
        for (index, card) in cards.enumerated() {
            let spot = potSpot + [Float.random(in: -0.08...0.08), 0.003, Float.random(in: 0.0...0.05)]
            let heading = simd_quatf(angle: Float.random(in: -1...1), axis: [0, 1, 0])
            animator.launch(card.entity, to: spot, orientation: heading, arc: 0.05, duration: 0.45, delay: Float(index) * 0.05)
            animator.fade(card.entity, to: 0, duration: 0.3, delay: 0.35 + Float(index) * 0.05)
        }
        await animator.wait(0.75)
        cards.forEach { $0.entity.removeFromParent() }
    }

    private func dealBoard(_ street: Street, _ cards: [Card]) async {
        guard let textures else { return }
        await gatherBets()
        for avatar in avatars.keys {
            gazes[avatar] = (.board, time + Float.random(in: 2...3))
        }

        var dealt: [CardEntity] = []
        for (offset, card) in cards.enumerated() {
            let entity = CardEntity(card, textures: textures, width: Self.boardCardWidth)
            entity.entity.position = shoeSpot + [0, 0.06, 0]
            entity.entity.orientation = shoe.orientation
            world.addChild(entity.entity)
            let spot = boardSpot(boardCards.count)
            boardCards.append(entity)
            dealt.append(entity)
            let delay = Float(offset) * 0.15
            animator.launch(entity.entity, to: spot.position, orientation: spot.orientation, arc: 0.08, spins: 0.5, duration: 0.35, delay: delay)
            animator.run(duration: 0, delay: delay) { [sounds, shoe] _ in sounds.play(.cardFlick, from: shoe) }
        }
        await animator.wait(Float(cards.count - 1) * 0.15 + 0.45)

        // The flop turns over in a quick ripple; the turn and river lift higher and slower for suspense.
        let (lift, duration, pause): (Float, Float, Float) = switch street {
        case .flop: (0.05, 0.35, 0)
        case .turn: (0.09, 0.55, 0.2)
        default: (0.13, 0.8, 0.45)
        }
        await animator.wait(pause)
        for (index, card) in dealt.enumerated() {
            let delay = Float(index) * 0.18
            animator.run(duration: 0, delay: delay + duration * 0.4) { [sounds] _ in sounds.play(.cardFlip, from: card.entity) }
            if index == dealt.count - 1 {
                await card.flip(using: animator, lift: lift, duration: duration, delay: delay)
            } else {
                Task { await card.flip(using: animator, lift: lift, duration: duration, delay: delay) }
            }
        }
    }

    private func showdown(_ hands: [PlayerID: EvaluatedHand], in game: HoldemGame) async {
        await gatherBets()
        guard let dealer = game.dealerIndex else { return }
        let order = (1...game.players.count).map { game.players[(dealer + $0) % game.players.count].id }

        // Turn over each hand in seat order.
        for id in order where hands[id] != nil && id != Self.human {
            for other in avatars.keys where other != id {
                gazes[other] = (.player(id), time + 1)
            }
            for (index, card) in (holeCards[id] ?? []).enumerated() {
                animator.run(duration: 0, delay: Float(index) * 0.12 + 0.15) { [sounds] _ in sounds.play(.cardFlip, from: card.entity) }
                Task { await card.flip(using: animator, lift: 0.07, duration: 0.45, delay: Float(index) * 0.12) }
            }
            callout(hands[id]!.value.category.name, for: id, color: .white, height: 0.04)
            await animator.wait(0.8)
        }

        // Light up the winning five cards and dim the rest.
        let winners = Set(game.lastResult?.winnings.keys.map { $0 } ?? [])
        var winning = Set<Card>()
        for id in winners {
            winning.formUnion(hands[id]?.bestFive ?? [])
        }
        let candidates = boardCards + winners.flatMap { holeCards[$0] ?? [] }
        for card in candidates where winning.contains(card.card) {
            card.highlight(using: animator)
        }
        for card in allCards where !(winning.contains(card.card) && candidates.contains { $0 === card }) {
            animator.fade(card.entity, to: 0.4, duration: 0.5)
        }

        if let best = winners.compactMap({ hands[$0] }).first {
            let names = order.filter(winners.contains).map { game.player($0)!.name }
            let title = winners.count > 1
                ? "Split pot · \(best.value.category.name)"
                : winners.contains(Self.human) ? "You win with \(best.value.category.name)!" : "\(names[0]) wins with \(best.value.category.name)"
            showBanner(title)
        }
        await animator.wait(0.9)
    }

    private func award(_ amount: Int, to winners: [PlayerID], in game: HoldemGame) async {
        await gatherBets()
        if banner == nil, let first = winners.first {
            showBanner(first == Self.human ? "You win \(amount)" : "\(game.player(first)!.name) wins \(amount)")
        }

        let share = amount / max(winners.count, 1)
        potChips = max(0, potChips - amount)
        pot.update(chips: potChips)
        sounds.play(.chipShower, from: pot.entity)
        let discs = min(max(amount / 25, 5), 16)
        for winner in winners {
            celebrate(winner)
            Task {
                await flyChips(discs, from: pot.top, to: stackSpot(winner), arc: 0.18, duration: 0.6, stagger: 0.045)
                stackChips[winner, default: 0] += share
                stacks[winner]?.update(chips: stackChips[winner]!)
                sounds.play(.chipShower, from: stacks[winner]!.entity)
            }
        }
        await animator.wait(Float(discs) * 0.045 + 0.9)
    }

    private func celebrate(_ id: PlayerID) {
        celebrateUntil[id] = time + 2.4
        if let avatar = avatars[id] {
            fireworks(at: avatar.headPosition + [0, 0.5, 0], scale: 0.25)
            sounds.play(.winChime, from: avatar.root, gain: -4)
            for other in avatars.keys where other != id {
                gazes[other] = (.player(id), time + 1.5)
            }
        } else {
            // You won: bigger show over the middle of the table, and everyone looks your way.
            fireworks(at: CardRoomLayout.tableCenter + [0, 1.5, 0], scale: 0.4)
            sounds.play(.winChime, from: controlsAnchor)
            for other in avatars.keys {
                gazes[other] = (.player(id), time + 1.8)
            }
        }
        lampPulse(to: UIColor(red: 1, green: 0.8, blue: 0.45, alpha: 1), intensity: 1.5, attack: 0.2, hold: 0.8, release: 1.2)
    }

    // MARK: - Chips

    private func bet(_ amount: Int, by id: PlayerID, discs: Int? = nil, stagger: Float = 0.05) async {
        guard amount > 0, let stack = stacks[id], let target = bets[id] else { return }
        stackChips[id, default: 0] -= amount
        let from = stack.top
        stack.update(chips: stackChips[id]!)
        sounds.play(.chipClack, from: stack.entity)
        await flyChips(discs ?? min(max(amount / 15, 1), 8), from: from, to: target.top, arc: 0.07, duration: 0.4, stagger: stagger)
        betChips[id, default: 0] += amount
        target.update(chips: betChips[id]!)
        sounds.play(.chipClack, from: target.entity, gain: -3)
    }

    private func returnBet(_ amount: Int, to id: PlayerID) async {
        guard let bet = bets[id], let stack = stacks[id] else { return }
        betChips[id, default: 0] -= amount
        let from = bet.top
        bet.update(chips: betChips[id]!)
        await flyChips(min(max(amount / 15, 1), 6), from: from, to: stack.top, arc: 0.06, duration: 0.35, stagger: 0.04)
        stackChips[id, default: 0] += amount
        stack.update(chips: stackChips[id]!)
    }

    /// Sweeps every bet into the pot at the end of a betting round.
    private func gatherBets() async {
        let betting = betChips.filter { $0.value > 0 }
        guard !betting.isEmpty else { return }
        sounds.play(.chipShower, from: pot.entity, gain: -3)
        for (id, amount) in betting {
            let from = bets[id]!.top
            betChips[id] = 0
            bets[id]!.update(chips: 0)
            Task { await flyChips(min(max(amount / 15, 2), 8), from: from, to: pot.top, arc: 0.06, duration: 0.45, stagger: 0.03) }
        }
        await animator.wait(0.75)
        potChips += betting.values.reduce(0, +)
        pot.update(chips: potChips)
    }

    private func flyChips(_ count: Int, from: SIMD3<Float>, to: SIMD3<Float>, arc: Float, duration: Float, stagger: Float) async {
        for index in 0..<count {
            let disc = ModelEntity(mesh: chipMesh, materials: [chipMaterials.randomElement()!])
            disc.position = from + [0, Float(index) * ChipStack.discHeight, 0]
            world.addChild(disc)
            let delay = Float(index) * stagger
            let landing = to + [Float.random(in: -0.004...0.004), Float(index % 6) * ChipStack.discHeight, Float.random(in: -0.004...0.004)]
            animator.launch(disc, to: landing, arc: arc, duration: duration, delay: delay)
            animator.run(duration: 0, delay: delay + duration) { _ in disc.removeFromParent() }
        }
        await animator.wait(Float(max(count - 1, 0)) * stagger + duration)
    }

    // MARK: - Effects

    /// Floating text over a player that pops in, drifts up and fades. Skipped for your own routine
    /// moves, since you just made them.
    private func callout(_ text: String, for id: PlayerID, color: UIColor, height: Float = 0.045, hold: Float = 0.9, evenForYou: Bool = false) {
        guard id != Self.human || evenForYou else { return }
        let label = Label3D.make(text, height: height, color: color)
        let position = calloutSpot(id)
        label.position = position
        label.orientation = CardRoomLayout.facing(from: position, to: CardRoomLayout.humanHead)
        world.addChild(label)
        animator.pop(label, duration: 0.35)
        animator.run(duration: 0.8, delay: hold) { progress in
            label.position.y = position.y + 0.06 * Ease.outCubic(progress)
        }
        animator.fade(label, to: 0, duration: 0.8, delay: hold)
        animator.run(duration: 0, delay: hold + 0.8) { _ in label.removeFromParent() }
    }

    private func showBanner(_ text: String) {
        let label = Label3D.make(text, height: 0.07, color: UIColor(red: 1, green: 0.82, blue: 0.35, alpha: 1))
        let position = CardRoomLayout.tableCenter + [0, 1.32, 0.05]
        label.position = position
        label.orientation = CardRoomLayout.facing(from: position, to: CardRoomLayout.humanHead)
        world.addChild(label)
        animator.pop(label, duration: 0.6)
        banner = label
    }

    private func fireworks(at position: SIMD3<Float>, scale: Float) {
        let emitter = Entity()
        var particles = ParticleEmitterComponent.Presets.fireworks
        particles.timing = .once(warmUp: nil, emit: .init(duration: 1.2))
        emitter.components.set(particles)
        emitter.position = position
        emitter.scale = .init(repeating: scale)
        world.addChild(emitter)
        animator.run(duration: 0, delay: 5) { _ in emitter.removeFromParent() }
    }

    /// Shifts the lamp toward a color and brightness, holds, then eases back.
    private func lampPulse(to color: UIColor, intensity scale: Float, attack: Float, hold: Float, release: Float) {
        let base = CardRoomBuilder.lampColor
        animator.run(duration: attack) { [weak self] progress in
            self?.setLamp(color: base.mixed(with: color, by: progress), intensity: 1 + (scale - 1) * progress)
        }
        animator.run(duration: release, delay: attack + hold) { [weak self] progress in
            self?.setLamp(color: color.mixed(with: base, by: progress), intensity: scale + (1 - scale) * progress)
        }
    }

    private func setLamp(color: UIColor, intensity: Float) {
        guard let lamp, var light = lamp.components[SpotLightComponent.self] else { return }
        light.color = color
        light.intensity = CardRoomBuilder.lampIntensity * intensity
        lamp.components.set(light)
    }

    // MARK: - Per frame

    func step(deltaTime: Float, table: HoldemTableModel) {
        animator.step(deltaTime)
        let game = table.game

        // Turn ring: glides to whoever is up and pulses; a chime when it's you.
        let current = game.isBetting ? game.currentPlayer?.id : nil
        if current != lastTurn {
            lastTurn = current
            if current == Self.human {
                sounds.play(.yourTurn, from: controlsAnchor, gain: -6)
            }
        }
        if let current {
            let target = holeSpot(current, 0).position + holeSpot(current, 1).position
            ringTarget = target / 2 + [0, 0.0025, 0]
        }
        if let ringTarget {
            let isShowing = current != nil
            if turnRing.components[OpacityComponent.self]?.opacity ?? 0 < 0.05 {
                turnRing.position = ringTarget // appear in place rather than sliding in from the last spot
            }
            turnRing.position += (ringTarget - turnRing.position) * min(1, deltaTime * 6)
            let pulse = isShowing ? 0.6 + 0.35 * sin(time * 4) : 0
            let opacity = turnRing.components[OpacityComponent.self]?.opacity ?? 0
            turnRing.components.set(OpacityComponent(opacity: opacity + (pulse - opacity) * min(1, deltaTime * 8)))
            turnRing.scale = .init(repeating: 1 + 0.04 * sin(time * 4))
        }

        for (id, avatar) in avatars {
            let player = game.player(id)!
            if gazes[id].map({ time >= $0.until }) ?? true {
                gazes[id] = (pickFocus(for: id, in: game), time + Float.random(in: 1.5...4))
            }
            avatar.pose = if (celebrateUntil[id] ?? 0) > time {
                .celebrate
            } else if (pushUntil[id] ?? 0) > time {
                .push
            } else if current == id {
                .thinking
            } else {
                .rest
            }
            avatar.animate(time: time, deltaTime: deltaTime, lookTarget: point(of: gazes[id]!.focus, for: id), isFolded: player.isInHand && player.hasFolded)
        }
    }

    /// Mostly the table, sometimes whoever is acting; you only get the occasional glance.
    private func pickFocus(for id: PlayerID, in game: HoldemGame) -> Focus {
        if game.currentPlayer?.id == id {
            return Double.random(in: 0..<1) < 0.75 ? .ownCards : .board
        }
        let roll = Double.random(in: 0..<1)
        if let current = game.currentPlayer?.id {
            let lookAtActor = current == Self.human ? 0.12 : 0.3
            if roll < lookAtActor { return .player(current) }
        }
        if roll < 0.55 { return .board }
        if roll < 0.7 { return .pot }
        return .ownCards
    }

    private func point(of focus: Focus, for id: PlayerID) -> SIMD3<Float> {
        switch focus {
        case .ownCards:
            return holeSpot(id, 0).position
        case .board:
            return boardSpot(2).position
        case .pot:
            return potSpot
        case .player(let other):
            if other == Self.human { return CardRoomLayout.humanHead }
            return avatars[other]?.headPosition ?? potSpot
        }
    }

    // MARK: - Dragging the controls

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
}

private extension UIColor {
    func mixed(with other: UIColor, by amount: Float) -> UIColor {
        var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let t = CGFloat(amount)
        return UIColor(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t, alpha: a1 + (a2 - a1) * t)
    }
}
