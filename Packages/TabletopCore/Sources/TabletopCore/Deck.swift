public struct Deck: Sendable {
    /// Remaining cards; the next card drawn is `cards.first`.
    public private(set) var cards: [Card]

    /// A stacked deck in the given order. Mainly for tests and replays.
    public init(cards: [Card]) {
        self.cards = cards
    }

    /// A freshly shuffled 52-card deck. Uses its own Fisher–Yates rather than `shuffled(using:)`
    /// so a given seed produces the same order on every device and Swift version.
    public init<G: RandomNumberGenerator>(using rng: inout G) {
        var cards = Card.fullDeck
        for i in stride(from: cards.count - 1, to: 0, by: -1) {
            let j = Int(rng.next() % UInt64(i + 1))
            cards.swapAt(i, j)
        }
        self.cards = cards
    }

    public var count: Int { cards.count }

    public mutating func draw() -> Card {
        precondition(!cards.isEmpty, "Drew from an empty deck")
        return cards.removeFirst()
    }
}

/// SplitMix64: small, fast and deterministic for a given seed.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
