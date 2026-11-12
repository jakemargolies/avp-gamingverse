import Foundation
import Observation
import TabletopCore

/// Shows what happens in the game, e.g. by animating it. After each move the model hands the new
/// events to the presenter and waits for it before publishing the new state and moving on.
@MainActor
protocol GamePresenter: AnyObject {
    func present(_ events: [GameEvent], from before: HoldemGame, to after: HoldemGame) async
}

/// Runs a single-player game: you against bots. Wraps the `HoldemGame` engine, plays the bots'
/// turns with a short delay so you can follow along, and exposes what the table views need.
@MainActor @Observable
final class HoldemTableModel {
    static let humanID: PlayerID = "you"
    static let botNames = ["Ada", "Basil", "Cleo", "Dmitri", "Esme"]

    /// The state the views show. Trails `engine` while the presenter animates what just happened.
    private(set) var game: HoldemGame
    /// Each player's latest action on the current street (folds stay for the whole hand).
    private(set) var lastActions: [PlayerID: PlayerAction] = [:]
    /// True while bots are playing or a move is being presented; your controls wait for it.
    private(set) var isBusy = false
    let botCount: Int
    @ObservationIgnored weak var presenter: (any GamePresenter)?
    /// Development aid: plays your turns too (checking or calling), so whole hands run unattended.
    @ObservationIgnored var autopilot = false

    private var engine: HoldemGame
    private let bots: [PlayerID: HoldemBot]
    private var rng: SeededGenerator
    private var playTask: Task<Void, Never>?

    init(botCount: Int, startingChips: Int = 1000, seed: UInt64 = .random(in: .min ... .max)) {
        let names = Self.botNames.prefix(botCount)
        let humans = [Player(id: Self.humanID, name: "You", chips: startingChips)]
        let botPlayers = names.map { Player(id: PlayerID($0), name: $0, chips: startingChips, isBot: true) }
        let game = HoldemGame(players: humans + botPlayers, smallBlind: 5, bigBlind: 10, seed: seed)
        engine = game
        self.game = game
        // Spread personalities from tight-passive to loose-aggressive.
        bots = Dictionary(uniqueKeysWithValues: names.enumerated().map { index, name in
            (PlayerID(name), HoldemBot(aggression: 0.2 + 0.6 * Double(index) / Double(max(botCount - 1, 1))))
        })
        rng = SeededGenerator(seed: seed &+ 1)
        self.botCount = botCount
    }

    // MARK: - Queries

    var human: Player { game.player(Self.humanID)! }
    var botPlayers: [Player] { game.players.filter(\.isBot) }
    var humanLegalActions: LegalActions? { isBusy ? nil : game.legalActions(for: Self.humanID) }

    /// Over once you're out of chips or have won everyone else's.
    var isGameOver: Bool { !game.isBetting && (human.chips == 0 || !game.canStartHand) }

    func isDealer(_ id: PlayerID) -> Bool {
        game.dealerIndex.map { game.players[$0].id == id } ?? false
    }

    func isCurrentPlayer(_ id: PlayerID) -> Bool { game.currentPlayer?.id == id }

    /// A player's hand once it's been shown at showdown.
    func revealedHand(of id: PlayerID) -> EvaluatedHand? {
        game.phase == .handComplete ? game.lastResult?.shownHands[id] : nil
    }

    func winnings(of id: PlayerID) -> Int? {
        game.phase == .handComplete ? game.lastResult?.winnings[id] : nil
    }

    /// Your best hand so far, once the flop is out.
    var humanHandName: String? {
        guard human.isLive, game.community.count >= 3 else { return nil }
        return HandEvaluator.evaluate(human.holeCards + game.community).value.category.name
    }

    /// One-line status under a player's name: their winnings, shown hand, latest action or bet.
    func seatStatus(of id: PlayerID) -> String {
        let player = game.player(id)!
        if let won = winnings(of: id) { return "Wins \(won)" }
        if let revealed = revealedHand(of: id) { return revealed.value.category.name }
        if !player.isInHand && player.chips == 0 { return "Out" }
        if player.isAllIn { return "All in" }
        if let action = lastActions[id] {
            return action == .call || action == .check ? "\(action.label) · \(player.streetBet)" : action.label
        }
        return player.streetBet > 0 ? "Bet \(player.streetBet)" : " "
    }

    /// e.g. "Basil wins 120 with Two Pair".
    var resultSummary: String? {
        guard game.phase == .handComplete, let result = game.lastResult else { return nil }
        return result.winnings.sorted { $0.value > $1.value }.map { id, amount in
            let name = game.player(id)!.name
            let verb = id == Self.humanID ? "win" : "wins"
            if let hand = result.shownHands[id] {
                return "\(name) \(verb) \(amount) with \(hand.value.category.name)"
            }
            return "\(name) \(verb) \(amount)"
        }.joined(separator: "\n")
    }

    // MARK: - Commands

    func dealNextHand() {
        guard !isGameOver, !isBusy else { return }
        lastActions = [:]
        do {
            try engine.startHand()
        } catch {
            assertionFailure("Couldn't start hand: \(error)")
            return
        }
        playUntilYourTurn()
    }

    func act(_ action: PlayerAction) {
        guard !isBusy, engine.currentPlayer?.id == Self.humanID else { return }
        apply(action, by: Self.humanID)
        playUntilYourTurn()
    }

    private func apply(_ action: PlayerAction, by id: PlayerID) {
        let phaseBefore = engine.phase
        do {
            try engine.apply(action, by: id)
        } catch {
            assertionFailure("\(id) tried an illegal action \(action): \(error)")
            return
        }
        lastActions[id] = action
        if engine.phase != phaseBefore {
            lastActions = lastActions.filter { $0.value == .fold }
        }
    }

    /// Presents the latest move, then plays bot turns until it's your turn or the hand is over.
    private func playUntilYourTurn() {
        isBusy = true
        playTask = Task {
            await publish()
            while let player = engine.currentPlayer, player.isBot || autopilot {
                // A moment to "think"; quicker once you've folded and are just watching.
                let delay = human.isLive ? Int.random(in: 700...1400) : 350
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled else { break }
                apply(decision(for: player), by: player.id)
                await publish()
            }
            isBusy = false
        }
    }

    private func decision(for player: Player) -> PlayerAction {
        if let bot = bots[player.id] {
            return bot.decide(for: player.id, in: engine, using: &rng)
        }
        return engine.legalActions(for: player.id)?.canCheck == true ? .check : .call
    }

    /// Lets the presenter show the new events, then shows the new state.
    private func publish() async {
        let newHand = engine.handNumber != game.handNumber
        let events = Array(engine.events.dropFirst(newHand ? 0 : game.events.count))
        if let presenter, !events.isEmpty {
            await presenter.present(events, from: game, to: engine)
        }
        game = engine
    }
}

extension PlayerAction {
    var label: String {
        switch self {
        case .fold: "Fold"
        case .check: "Check"
        case .call: "Call"
        case .raise(let to): "Raise to \(to)"
        }
    }
}
