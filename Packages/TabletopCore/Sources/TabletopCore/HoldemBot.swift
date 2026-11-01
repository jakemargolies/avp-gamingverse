/// A simple computer opponent. Estimates its equity by Monte Carlo simulation against random hands,
/// then raises, calls or folds based on that equity versus the pot odds. It only looks at its own
/// hole cards and the board, never at other players' cards.
public struct HoldemBot: Sendable {
    /// 0 plays tight and passive; 1 raises lighter and bluffs more often.
    public var aggression: Double
    public var simulations: Int

    public init(aggression: Double = 0.5, simulations: Int = 200) {
        self.aggression = aggression
        self.simulations = simulations
    }

    public func decide<G: RandomNumberGenerator>(for id: PlayerID, in game: HoldemGame, using rng: inout G) -> PlayerAction {
        guard let legal = game.legalActions(for: id), let me = game.player(id) else { return .fold }

        let opponents = game.players.filter { $0.isLive && $0.id != id }.count
        let equity = Self.estimateEquity(hole: me.holeCards, board: game.community, opponents: opponents, trials: simulations, using: &rng)
        // Equity relative to a fair share of the pot: 1.0 means exactly average for this many opponents.
        let strength = equity * Double(opponents + 1)
        let roll = Double.random(in: 0..<1, using: &rng)

        if let range = legal.raiseRange, strength > 1.35 - aggression * 0.25 || roll < aggression * 0.06 {
            let potFraction = 0.5 + min(max(strength - 1, 0), 1) * 0.5
            let target = game.currentBet + max(game.bigBlind, Int(Double(game.pot) * potFraction))
            return .raise(to: min(max(target, range.lowerBound), range.upperBound))
        }
        if legal.canCheck { return .check }

        let potOdds = Double(legal.callAmount) / Double(game.pot + legal.callAmount)
        if equity > potOdds || roll < aggression * 0.05 { return .call }
        return .fold
    }

    /// Fraction of the pot this hand wins on average against `opponents` random hands (ties split).
    public static func estimateEquity<G: RandomNumberGenerator>(hole: [Card], board: [Card], opponents: Int, trials: Int, using rng: inout G) -> Double {
        guard opponents > 0, trials > 0 else { return 1 }
        let known = Set(hole + board)
        var unseen = Card.fullDeck.filter { !known.contains($0) }
        let boardNeeded = 5 - board.count
        let cardsNeeded = boardNeeded + opponents * 2

        var total = 0.0
        for _ in 0..<trials {
            // Partial shuffle: only the first `cardsNeeded` positions need to be random.
            for k in 0..<cardsNeeded {
                unseen.swapAt(k, Int.random(in: k..<unseen.count, using: &rng))
            }
            let fullBoard = board + unseen[0..<boardNeeded]
            let mine = HandEvaluator.evaluate(hole + fullBoard).value
            var lost = false
            var tied = 1
            for o in 0..<opponents {
                let start = boardNeeded + o * 2
                let theirs = HandEvaluator.evaluate(Array(unseen[start..<start + 2]) + fullBoard).value
                if theirs > mine {
                    lost = true
                    break
                }
                if theirs == mine { tied += 1 }
            }
            if !lost { total += 1 / Double(tied) }
        }
        return total / Double(trials)
    }
}
