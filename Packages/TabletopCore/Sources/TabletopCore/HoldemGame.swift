public struct PlayerID: Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }

    public var description: String { rawValue }
}

public struct Player: Identifiable, Codable, Sendable {
    public let id: PlayerID
    public var name: String
    public var isBot: Bool
    public internal(set) var chips: Int
    public internal(set) var holeCards: [Card] = []
    /// Chips put in during the current betting round.
    public internal(set) var streetBet = 0
    /// Chips put in during the whole hand; the pot is the sum of these.
    public internal(set) var handCommitted = 0
    /// Dealt into the current hand (had chips when it started).
    public internal(set) var isInHand = false
    public internal(set) var hasFolded = false
    public internal(set) var hasActed = false

    public init(id: PlayerID, name: String, chips: Int, isBot: Bool = false) {
        self.id = id
        self.name = name
        self.chips = chips
        self.isBot = isBot
    }

    /// Still contesting the pot.
    public var isLive: Bool { isInHand && !hasFolded }
    public var isAllIn: Bool { isLive && chips == 0 }
    public var canAct: Bool { isLive && chips > 0 }
}

public enum Street: Int, Codable, Sendable, Comparable {
    case preflop, flop, turn, river

    public static func < (lhs: Street, rhs: Street) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum Phase: Equatable, Codable, Sendable {
    case waitingForHand
    case betting(Street)
    case handComplete
}

public enum PlayerAction: Equatable, Codable, Sendable {
    case fold
    case check
    case call
    /// Bet or raise so the player's total bet this round equals `to`. Going all-in is a raise to `streetBet + chips`.
    case raise(to: Int)
}

public struct LegalActions: Equatable, Sendable {
    public var canCheck: Bool
    /// Chips needed to call, capped at the player's stack (a short call is an all-in).
    public var callAmount: Int
    /// Allowed totals for `.raise(to:)`, or nil if the player may not bet or raise.
    public var raiseRange: ClosedRange<Int>?
}

/// Things that happened during the current hand, in order, for the UI to animate.
public enum GameEvent: Equatable, Sendable {
    case handStarted(number: Int, dealer: PlayerID)
    case blindPosted(PlayerID, amount: Int)
    case holeCardsDealt
    case acted(PlayerID, PlayerAction)
    case communityDealt(Street, [Card])
    case uncalledBetReturned(PlayerID, amount: Int)
    case showdown([PlayerID: EvaluatedHand])
    case potAwarded(amount: Int, to: [PlayerID])
}

public struct Pot: Equatable, Sendable {
    public var amount: Int
    /// Players who can win this pot, in seat order starting left of the dealer.
    public var eligible: [PlayerID]
}

public struct HandResult: Equatable, Sendable {
    public var winnings: [PlayerID: Int]
    /// Hands revealed at showdown; empty when everyone else folded.
    public var shownHands: [PlayerID: EvaluatedHand]
}

public enum GameError: Error, Equatable {
    case cannotStartHand
    case noHandInProgress
    case notYourTurn
    case illegalAction(String)
}

/// No-limit Texas Hold'em rules engine. A plain value type: the UI holds one, feeds it actions,
/// and renders `players`, `community`, `pots` and `events`.
public struct HoldemGame: Sendable {
    public let smallBlind: Int
    public let bigBlind: Int
    public private(set) var players: [Player]
    public private(set) var phase: Phase = .waitingForHand
    public private(set) var community: [Card] = []
    public private(set) var dealerIndex: Int?
    public private(set) var currentPlayerIndex: Int?
    /// Highest total bet on the current street.
    public private(set) var currentBet = 0
    /// Size of the last full raise on this street; the next raise must be at least this much more.
    public private(set) var minRaise = 0
    public private(set) var handNumber = 0
    public private(set) var events: [GameEvent] = []
    public private(set) var lastResult: HandResult?

    private var deck = Deck(cards: [])
    private var rng: SeededGenerator

    public init(players: [Player], smallBlind: Int, bigBlind: Int, seed: UInt64) {
        precondition(players.count >= 2, "Hold'em needs at least two players")
        precondition(Set(players.map(\.id)).count == players.count, "Player IDs must be unique")
        self.players = players
        self.smallBlind = smallBlind
        self.bigBlind = bigBlind
        rng = SeededGenerator(seed: seed)
    }

    // MARK: - Queries

    public var isBetting: Bool {
        if case .betting = phase { return true }
        return false
    }

    public var canStartHand: Bool {
        !isBetting && players.filter { $0.chips > 0 }.count >= 2
    }

    public var currentPlayer: Player? { currentPlayerIndex.map { players[$0] } }

    public var pot: Int { players.reduce(0) { $0 + $1.handCommitted } }

    public func player(_ id: PlayerID) -> Player? { players.first { $0.id == id } }

    /// The pot split into main and side pots according to how much each live player could cover.
    public var pots: [Pot] {
        let levels = Set(players.map(\.handCommitted).filter { $0 > 0 }).sorted()
        let order = seatOrderFromDealer()
        var pots: [Pot] = []
        var previous = 0
        for level in levels {
            let amount = players.reduce(0) { $0 + min($1.handCommitted, level) - min($1.handCommitted, previous) }
            var eligible = order.filter { players[$0].isLive && players[$0].handCommitted >= level }.map { players[$0].id }
            if eligible.isEmpty && pots.isEmpty {
                eligible = order.filter { players[$0].isLive }.map { players[$0].id }
            }
            if let last = pots.indices.last, eligible.isEmpty || pots[last].eligible == eligible {
                // Same contenders as the previous layer (or chips only folded players reached): merge.
                pots[last].amount += amount
            } else {
                pots.append(Pot(amount: amount, eligible: eligible))
            }
            previous = level
        }
        return pots
    }

    public func legalActions(for id: PlayerID) -> LegalActions? {
        guard isBetting, let i = currentPlayerIndex, players[i].id == id else { return nil }
        let player = players[i]
        let toCall = max(0, currentBet - player.streetBet)
        let maxTo = player.streetBet + player.chips
        let someoneCanRespond = players.indices.contains { $0 != i && players[$0].canAct }
        // A player who already acted is only back because of a short all-in, which doesn't reopen raising.
        var raiseRange: ClosedRange<Int>?
        if someoneCanRespond, !player.hasActed, player.chips > toCall {
            raiseRange = min(currentBet + minRaise, maxTo)...maxTo
        }
        return LegalActions(canCheck: toCall == 0, callAmount: min(toCall, player.chips), raiseRange: raiseRange)
    }

    // MARK: - Commands

    public mutating func startHand() throws {
        try startHand(deck: nil)
    }

    mutating func startHand(deck stacked: Deck?) throws {
        guard canStartHand else { throw GameError.cannotStartHand }
        handNumber += 1
        events = []
        lastResult = nil
        community = []
        currentBet = 0
        minRaise = bigBlind
        for i in players.indices {
            players[i].holeCards = []
            players[i].streetBet = 0
            players[i].handCommitted = 0
            players[i].hasFolded = false
            players[i].hasActed = false
            players[i].isInHand = players[i].chips > 0
        }

        let dealer = nextIndex(after: dealerIndex ?? players.count - 1) { $0.isInHand }!
        dealerIndex = dealer
        deck = stacked ?? Deck(using: &rng)
        events.append(.handStarted(number: handNumber, dealer: players[dealer].id))

        // Heads-up, the dealer posts the small blind and acts first before the flop.
        let headsUp = players.filter(\.isInHand).count == 2
        let smallBlindSeat = headsUp ? dealer : nextIndex(after: dealer) { $0.isInHand }!
        let bigBlindSeat = nextIndex(after: smallBlindSeat) { $0.isInHand }!
        postBlind(smallBlind, from: smallBlindSeat)
        postBlind(bigBlind, from: bigBlindSeat)
        currentBet = bigBlind

        for _ in 0..<2 {
            var seat = dealer
            repeat {
                seat = nextIndex(after: seat) { $0.isInHand }!
                players[seat].holeCards.append(deck.draw())
            } while seat != dealer
        }
        events.append(.holeCardsDealt)

        phase = .betting(.preflop)
        currentPlayerIndex = bigBlindSeat
        advanceTurn()
    }

    public mutating func apply(_ action: PlayerAction, by id: PlayerID) throws {
        guard isBetting, let i = currentPlayerIndex else { throw GameError.noHandInProgress }
        guard players[i].id == id, let legal = legalActions(for: id) else { throw GameError.notYourTurn }

        switch action {
        case .fold:
            players[i].hasFolded = true
        case .check:
            guard legal.canCheck else { throw GameError.illegalAction("Cannot check facing a bet of \(currentBet)") }
        case .call:
            guard legal.callAmount > 0 else { throw GameError.illegalAction("Nothing to call; check instead") }
            commit(legal.callAmount, from: i)
        case .raise(let to):
            guard let range = legal.raiseRange else { throw GameError.illegalAction("Raising is not allowed here") }
            guard range.contains(to) else { throw GameError.illegalAction("Raise must be to between \(range.lowerBound) and \(range.upperBound)") }
            let increment = to - currentBet
            if increment >= minRaise {
                // A full raise reopens the action for everyone else.
                minRaise = increment
                for j in players.indices where j != i { players[j].hasActed = false }
            }
            currentBet = to
            commit(to - players[i].streetBet, from: i)
        }
        players[i].hasActed = true
        events.append(.acted(id, action))
        advanceTurn()
    }

    // MARK: - Flow

    private mutating func advanceTurn() {
        let live = players.indices.filter { players[$0].isLive }
        if live.count == 1 {
            finishUncontested(winner: live[0])
        } else if bettingRoundIsComplete {
            endBettingRound()
        } else {
            let bet = currentBet
            currentPlayerIndex = nextIndex(after: currentPlayerIndex!) { $0.canAct && (!$0.hasActed || $0.streetBet < bet) }
        }
    }

    private var bettingRoundIsComplete: Bool {
        let actors = players.filter(\.canAct)
        if actors.count <= 1 {
            // Everyone else is all-in or folded; the last player only needs to match the bet.
            return actors.allSatisfy { $0.streetBet >= currentBet }
        }
        return actors.allSatisfy { $0.hasActed && $0.streetBet == currentBet }
    }

    private mutating func endBettingRound() {
        currentPlayerIndex = nil
        returnUncalledBet()
        guard case .betting(let street) = phase else { return }
        if street == .river {
            showdown()
            return
        }

        for i in players.indices {
            players[i].streetBet = 0
            players[i].hasActed = false
        }
        currentBet = 0
        minRaise = bigBlind

        let next = Street(rawValue: street.rawValue + 1)!
        _ = deck.draw() // burn
        let cards = (0..<(next == .flop ? 3 : 1)).map { _ in deck.draw() }
        community += cards
        events.append(.communityDealt(next, cards))
        phase = .betting(next)

        if players.filter(\.canAct).count < 2 {
            endBettingRound() // nobody left to bet against: run out the board
        } else {
            currentPlayerIndex = nextIndex(after: dealerIndex!) { $0.canAct }
        }
    }

    private mutating func returnUncalledBet() {
        let bettors = players.indices.filter { players[$0].isInHand }.sorted { players[$0].streetBet > players[$1].streetBet }
        guard bettors.count >= 2 else { return }
        let top = bettors[0]
        let excess = players[top].streetBet - players[bettors[1]].streetBet
        guard excess > 0 else { return }
        players[top].streetBet -= excess
        players[top].handCommitted -= excess
        players[top].chips += excess
        events.append(.uncalledBetReturned(players[top].id, amount: excess))
    }

    private mutating func finishUncontested(winner: Int) {
        currentPlayerIndex = nil
        returnUncalledBet()
        let amount = pot
        events.append(.potAwarded(amount: amount, to: [players[winner].id]))
        finishHand(winnings: [players[winner].id: amount], shownHands: [:])
    }

    private mutating func showdown() {
        var shown: [PlayerID: EvaluatedHand] = [:]
        for player in players where player.isLive {
            shown[player.id] = HandEvaluator.evaluate(player.holeCards + community)
        }
        events.append(.showdown(shown))

        var winnings: [PlayerID: Int] = [:]
        for pot in pots {
            let best = pot.eligible.compactMap { shown[$0]?.value }.max()
            let winners = pot.eligible.filter { shown[$0]?.value == best }
            // Odd chips go to the winners closest to the dealer's left (eligible is already in that order).
            let share = pot.amount / winners.count
            let oddChips = pot.amount % winners.count
            for (n, winner) in winners.enumerated() {
                winnings[winner, default: 0] += share + (n < oddChips ? 1 : 0)
            }
            events.append(.potAwarded(amount: pot.amount, to: winners))
        }
        finishHand(winnings: winnings, shownHands: shown)
    }

    private mutating func finishHand(winnings: [PlayerID: Int], shownHands: [PlayerID: EvaluatedHand]) {
        for (id, amount) in winnings {
            let i = players.firstIndex { $0.id == id }!
            players[i].chips += amount
        }
        for i in players.indices {
            players[i].streetBet = 0
            players[i].handCommitted = 0
        }
        lastResult = HandResult(winnings: winnings, shownHands: shownHands)
        phase = .handComplete
    }

    // MARK: - Helpers

    private mutating func postBlind(_ amount: Int, from seat: Int) {
        let posted = min(amount, players[seat].chips)
        commit(posted, from: seat)
        events.append(.blindPosted(players[seat].id, amount: posted))
    }

    private mutating func commit(_ amount: Int, from seat: Int) {
        players[seat].chips -= amount
        players[seat].streetBet += amount
        players[seat].handCommitted += amount
    }

    /// The first seat after `seat` (wrapping, and ending with `seat` itself) that matches `predicate`.
    private func nextIndex(after seat: Int, where predicate: (Player) -> Bool) -> Int? {
        for offset in 1...players.count {
            let candidate = (seat + offset) % players.count
            if predicate(players[candidate]) { return candidate }
        }
        return nil
    }

    private func seatOrderFromDealer() -> [Int] {
        let dealer = dealerIndex ?? players.count - 1
        return (1...players.count).map { (dealer + $0) % players.count }
    }
}
