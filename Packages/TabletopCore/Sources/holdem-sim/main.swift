import TabletopCore

// Usage: holdem-sim [seed] [maxHands]
// Plays bots against each other, prints each hand, and checks that no chips are created or lost.

let arguments = CommandLine.arguments
let seed = arguments.count > 1 ? UInt64(arguments[1]) ?? 1 : 1
let maxHands = arguments.count > 2 ? Int(arguments[2]) ?? 50 : 50

let startingChips = 1000
let names = ["Ada", "Basil", "Cleo", "Dmitri"]
var game = HoldemGame(
    players: names.map { Player(id: PlayerID($0), name: $0, chips: startingChips, isBot: true) },
    smallBlind: 5,
    bigBlind: 10,
    seed: seed
)
let bots = Dictionary(uniqueKeysWithValues: zip(names.map { PlayerID($0) }, [0.2, 0.4, 0.6, 0.8].map { HoldemBot(aggression: $0) }))
var rng = SeededGenerator(seed: seed &+ 1)

func describe(_ event: GameEvent) -> String {
    switch event {
    case .handStarted(let number, let dealer): "Hand #\(number), dealer \(dealer)"
    case .blindPosted(let id, let amount): "  \(id) posts \(amount)"
    case .holeCardsDealt: "  Hole cards: " + game.players.filter(\.isInHand).map { "\($0.name) \($0.holeCards.map(\.description).joined(separator: " "))" }.joined(separator: ", ")
    case .acted(let id, let action): "  \(id) \(action)"
    case .communityDealt(let street, let cards): "  \(street): \(cards.map(\.description).joined(separator: " "))"
    case .uncalledBetReturned(let id, let amount): "  \(amount) returned to \(id)"
    case .showdown(let hands): "  Showdown: " + hands.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key) \($0.value.value.category.name)" }.joined(separator: ", ")
    case .potAwarded(let amount, let winners): "  Pot of \(amount) to \(winners.map(\.rawValue).joined(separator: " & "))"
    }
}

let totalChips = startingChips * names.count
while game.canStartHand && game.handNumber < maxHands {
    try game.startHand()
    while let player = game.currentPlayer {
        let action = bots[player.id]!.decide(for: player.id, in: game, using: &rng)
        try game.apply(action, by: player.id)
    }
    game.events.forEach { print(describe($0)) }

    let chips = game.players.map(\.chips).reduce(0, +)
    precondition(chips == totalChips, "Chip count drifted to \(chips) after hand \(game.handNumber)")
    print("  Stacks: " + game.players.map { "\($0.name) \($0.chips)" }.joined(separator: ", ") + "\n")
}
print("Finished after \(game.handNumber) hands; chips conserved.")
