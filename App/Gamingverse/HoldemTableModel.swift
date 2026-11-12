import Foundation
import Observation
import TabletopCore

/// Runs a single-player game: you against bots. Wraps the `HoldemGame` engine, plays the bots'
/// turns with a short delay so you can follow along, and exposes what the table views need.
@MainActor @Observable
final class HoldemTableModel {
    static let humanID: PlayerID = "you"
    static let botNames = ["Ada", "Basil", "Cleo", "Dmitri", "Esme"]

    private(set) var game: HoldemGame
    /// Each player's latest action on the current street (folds stay for the whole hand).
    private(set) var lastActions: [PlayerID: PlayerAction] = [:]
    let botCount: Int

    private let bots: [PlayerID: HoldemBot]
    private var rng: SeededGenerator
    private var botTask: Task<Void, Never>?

    init(botCount: Int, startingChips: Int = 1000, seed: UInt64 = .random(in: .min ... .max)) {
        let names = Self.botNames.prefix(botCount)
        let humans = [Player(id: Self.humanID, name: "You", chips: startingChips)]
        let botPlayers = names.map { Player(id: PlayerID($0), name: $0, chips: startingChips, isBot: true) }
        game = HoldemGame(players: humans + botPlayers, smallBlind: 5, bigBlind: 10, seed: seed)
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
    var humanLegalActions: LegalActions? { game.legalActions(for: Self.humanID) }

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
        guard !isGameOver else { return }
        lastActions = [:]
        do {
            try game.startHand()
        } catch {
            assertionFailure("Couldn't start hand: \(error)")
        }
        runBots()
    }

    func act(_ action: PlayerAction) {
        guard isCurrentPlayer(Self.humanID) else { return }
        apply(action, by: Self.humanID)
        runBots()
    }

    private func apply(_ action: PlayerAction, by id: PlayerID) {
        let phaseBefore = game.phase
        do {
            try game.apply(action, by: id)
        } catch {
            assertionFailure("\(id) tried an illegal action \(action): \(error)")
            return
        }
        lastActions[id] = action
        if game.phase != phaseBefore {
            lastActions = lastActions.filter { $0.value == .fold }
        }
    }

    /// Plays bot turns until it's your turn or the hand is over.
    private func runBots() {
        botTask?.cancel()
        botTask = Task {
            while let bot = game.currentPlayer, bot.isBot {
                // Move faster once you've folded and are just watching.
                try? await Task.sleep(for: human.isLive ? .milliseconds(900) : .milliseconds(400))
                guard !Task.isCancelled else { return }
                let action = bots[bot.id]!.decide(for: bot.id, in: game, using: &rng)
                apply(action, by: bot.id)
            }
        }
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
