public enum Suit: Int, CaseIterable, Codable, Sendable {
    case clubs, diamonds, hearts, spades

    public var symbol: String {
        switch self {
        case .clubs: "♣"
        case .diamonds: "♦"
        case .hearts: "♥"
        case .spades: "♠"
        }
    }

    public var isRed: Bool { self == .diamonds || self == .hearts }
}

public enum Rank: Int, CaseIterable, Comparable, Codable, Sendable {
    case two = 2, three, four, five, six, seven, eight, nine, ten, jack, queen, king, ace

    public static func < (lhs: Rank, rhs: Rank) -> Bool { lhs.rawValue < rhs.rawValue }

    public var symbol: String {
        switch self {
        case .ten: "T"
        case .jack: "J"
        case .queen: "Q"
        case .king: "K"
        case .ace: "A"
        default: String(rawValue)
        }
    }
}

public struct Card: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rank: Rank
    public let suit: Suit

    public init(_ rank: Rank, _ suit: Suit) {
        self.rank = rank
        self.suit = suit
    }

    /// Parses short notation such as "Ah", "Td" or "2c".
    public init?(_ notation: String) {
        guard notation.count == 2,
              let rank = Rank.allCases.first(where: { $0.symbol == String(notation.prefix(1)).uppercased() }),
              let suit = ["c": Suit.clubs, "d": .diamonds, "h": .hearts, "s": .spades][notation.suffix(1).lowercased()]
        else { return nil }
        self.init(rank, suit)
    }

    public static let fullDeck: [Card] = Suit.allCases.flatMap { suit in Rank.allCases.map { Card($0, suit) } }

    public var description: String { rank.symbol + suit.symbol }
}
