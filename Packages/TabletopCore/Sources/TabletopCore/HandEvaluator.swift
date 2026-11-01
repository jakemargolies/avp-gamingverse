public enum HandCategory: Int, Comparable, Codable, Sendable {
    case highCard, onePair, twoPair, threeOfAKind, straight, flush, fullHouse, fourOfAKind, straightFlush

    public static func < (lhs: HandCategory, rhs: HandCategory) -> Bool { lhs.rawValue < rhs.rawValue }

    public var name: String {
        switch self {
        case .highCard: "High Card"
        case .onePair: "Pair"
        case .twoPair: "Two Pair"
        case .threeOfAKind: "Three of a Kind"
        case .straight: "Straight"
        case .flush: "Flush"
        case .fullHouse: "Full House"
        case .fourOfAKind: "Four of a Kind"
        case .straightFlush: "Straight Flush"
        }
    }
}

/// The strength of a five-card poker hand. Two values compare equal exactly when the hands tie.
public struct HandValue: Comparable, Hashable, Codable, Sendable {
    public let category: HandCategory
    /// Ranks that break ties within the category, most significant first
    /// (e.g. full house: [trips rank, pair rank]; flush: all five ranks descending).
    public let tiebreakers: [Rank]

    public static func < (lhs: HandValue, rhs: HandValue) -> Bool {
        if lhs.category != rhs.category { return lhs.category < rhs.category }
        return lhs.tiebreakers.lexicographicallyPrecedes(rhs.tiebreakers)
    }
}

public struct EvaluatedHand: Equatable, Codable, Sendable {
    public let value: HandValue
    public let bestFive: [Card]
}

public enum HandEvaluator {
    /// Best five-card hand from 5–7 cards.
    public static func evaluate(_ cards: [Card]) -> EvaluatedHand {
        precondition((5...7).contains(cards.count), "Need 5 to 7 cards, got \(cards.count)")
        var best: EvaluatedHand?
        forEachFiveCardCombination(of: cards) { five in
            let value = value(ofFive: five)
            if best == nil || value > best!.value {
                best = EvaluatedHand(value: value, bestFive: five)
            }
        }
        return best!
    }

    static func value(ofFive cards: [Card]) -> HandValue {
        let ranks = cards.map(\.rank).sorted(by: >)
        let isFlush = Set(cards.map(\.suit)).count == 1

        var straightHigh: Rank?
        let distinct = Array(Set(ranks)).sorted(by: >)
        if distinct.count == 5 {
            if distinct[0].rawValue - distinct[4].rawValue == 4 {
                straightHigh = distinct[0]
            } else if distinct == [.ace, .five, .four, .three, .two] {
                straightHigh = .five // the wheel: ace plays low
            }
        }

        var counts: [Rank: Int] = [:]
        for rank in ranks { counts[rank, default: 0] += 1 }
        // Bigger groups first, then higher ranks: e.g. K K K 7 7 -> [(3, K), (2, 7)].
        let groups = counts.map { (count: $0.value, rank: $0.key) }.sorted { ($0.count, $0.rank) > ($1.count, $1.rank) }
        let shape = groups.map(\.count)
        let groupRanks = groups.map(\.rank)

        if let high = straightHigh, isFlush { return HandValue(category: .straightFlush, tiebreakers: [high]) }
        if shape == [4, 1] { return HandValue(category: .fourOfAKind, tiebreakers: groupRanks) }
        if shape == [3, 2] { return HandValue(category: .fullHouse, tiebreakers: groupRanks) }
        if isFlush { return HandValue(category: .flush, tiebreakers: ranks) }
        if let high = straightHigh { return HandValue(category: .straight, tiebreakers: [high]) }
        if shape == [3, 1, 1] { return HandValue(category: .threeOfAKind, tiebreakers: groupRanks) }
        if shape == [2, 2, 1] { return HandValue(category: .twoPair, tiebreakers: groupRanks) }
        if shape == [2, 1, 1, 1] { return HandValue(category: .onePair, tiebreakers: groupRanks) }
        return HandValue(category: .highCard, tiebreakers: ranks)
    }

    private static func forEachFiveCardCombination(of cards: [Card], _ body: ([Card]) -> Void) {
        let n = cards.count
        for a in 0..<n { for b in (a + 1)..<n { for c in (b + 1)..<n { for d in (c + 1)..<n { for e in (d + 1)..<n {
            body([cards[a], cards[b], cards[c], cards[d], cards[e]])
        } } } } }
    }
}
