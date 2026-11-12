import XCTest
@testable import TabletopCore

final class HoldemGameTests: XCTestCase {
    private func makeGame(_ stacks: [Int], smallBlind: Int = 1, bigBlind: Int = 2) -> HoldemGame {
        let players = stacks.enumerated().map { seat, chips in
            Player(id: PlayerID(["A", "B", "C", "D"][seat]), name: "P\(seat)", chips: chips)
        }
        return HoldemGame(players: players, smallBlind: smallBlind, bigBlind: bigBlind, seed: 42)
    }

    /// A deck that deals `holes[seat]` to each seat and runs out `board`, assuming everyone is dealt in.
    private func stackedDeck(dealer: Int, holes: [[String]], board: [String]) -> Deck {
        let card = { (notation: String) in Card(notation)! }
        let used = Set((holes.flatMap { $0 } + board).map(card))
        var spare = Card.fullDeck.filter { !used.contains($0) }
        let dealOrder = (1...holes.count).map { (dealer + $0) % holes.count }

        var cards = (0..<2).flatMap { round in dealOrder.map { card(holes[$0][round]) } }
        cards.append(spare.removeFirst())
        cards += board[0..<3].map(card)
        cards.append(spare.removeFirst())
        cards.append(card(board[3]))
        cards.append(spare.removeFirst())
        cards.append(card(board[4]))
        return Deck(cards: cards + spare)
    }

    func testHeadsUpDealerPostsSmallBlindAndActsFirstPreflopOnly() throws {
        var game = makeGame([100, 100], smallBlind: 5, bigBlind: 10)
        try game.startHand()
        XCTAssertEqual(game.dealerIndex, 0)
        XCTAssertEqual(game.players.map(\.streetBet), [5, 10])
        XCTAssertEqual(game.currentPlayer?.id, "A")

        try game.apply(.call, by: "A")
        XCTAssertEqual(game.currentPlayer?.id, "B", "Big blind gets the option")
        try game.apply(.check, by: "B")

        XCTAssertEqual(game.phase, .betting(.flop))
        XCTAssertEqual(game.community.count, 3)
        XCTAssertEqual(game.currentPlayer?.id, "B", "Non-dealer acts first after the flop")
    }

    func testEveryoneFoldsAndUncalledBetIsReturned() throws {
        var game = makeGame([100, 100, 100])
        try game.startHand()
        XCTAssertEqual(game.currentPlayer?.id, "A", "Seat after the big blind opens")

        try game.apply(.raise(to: 6), by: "A")
        try game.apply(.fold, by: "B")
        try game.apply(.fold, by: "C")

        XCTAssertEqual(game.phase, .handComplete)
        XCTAssertEqual(game.players.map(\.chips), [103, 99, 98])
        XCTAssertEqual(game.pot, 0)
        XCTAssertTrue(game.events.contains(.uncalledBetReturned("A", amount: 4)))
        XCTAssertEqual(game.lastResult?.winnings, ["A": 5])
    }

    func testSidePotGoesToPlayersWhoCoveredIt() throws {
        var game = makeGame([100, 50, 100])
        let deck = stackedDeck(dealer: 0, holes: [["Ks", "Kd"], ["As", "Ad"], ["7c", "2h"]], board: ["3s", "8d", "9c", "Jh", "4c"])
        try game.startHand(deck: deck)

        try game.apply(.raise(to: 100), by: "A")
        try game.apply(.call, by: "B") // all-in for 50
        try game.apply(.call, by: "C")

        XCTAssertEqual(game.phase, .handComplete)
        XCTAssertEqual(game.community.count, 5, "Board runs out once nobody can bet")
        XCTAssertEqual(game.players.map(\.chips), [100, 150, 0])
        XCTAssertEqual(game.lastResult?.winnings, ["B": 150, "A": 100])
    }

    func testSplitPotOddChipGoesLeftOfDealer() throws {
        var game = makeGame([100, 100, 100])
        let deck = stackedDeck(dealer: 0, holes: [["2c", "3d"], ["4c", "5d"], ["2d", "3c"]], board: ["As", "Ks", "Qs", "Js", "Ts"])
        try game.startHand(deck: deck)

        try game.apply(.call, by: "A")
        try game.apply(.fold, by: "B") // leaves 1 dead chip: pot of 5
        try game.apply(.check, by: "C")
        for _ in 0..<3 {
            try game.apply(.check, by: "C")
            try game.apply(.check, by: "A")
        }

        XCTAssertEqual(game.phase, .handComplete)
        XCTAssertEqual(game.lastResult?.winnings, ["C": 3, "A": 2])
        XCTAssertEqual(game.players.map(\.chips), [100, 99, 101])
    }

    func testRejectsOutOfTurnAndUndersizedRaises() throws {
        var game = makeGame([100, 100, 100])
        try game.startHand()

        XCTAssertThrowsError(try game.apply(.call, by: "B")) { XCTAssertEqual($0 as? GameError, .notYourTurn) }
        XCTAssertThrowsError(try game.apply(.check, by: "A"))
        XCTAssertThrowsError(try game.apply(.raise(to: 3), by: "A"))
        XCTAssertEqual(game.legalActions(for: "A")?.raiseRange, 4...100)
    }

    func testShortAllInRaiseDoesNotReopenBetting() throws {
        var game = makeGame([1000, 1000, 40], smallBlind: 5, bigBlind: 10)
        try game.startHand()

        try game.apply(.raise(to: 30), by: "A")
        try game.apply(.call, by: "B")
        XCTAssertEqual(game.legalActions(for: "C")?.raiseRange, 40...40)
        try game.apply(.raise(to: 40), by: "C") // all-in, only 10 more than the bet

        let legal = try XCTUnwrap(game.legalActions(for: "A"))
        XCTAssertEqual(legal.callAmount, 10)
        XCTAssertNil(legal.raiseRange)
    }

    func testBustedPlayersAreSkipped() throws {
        var game = makeGame([0, 100, 100])
        try game.startHand()
        XCTAssertFalse(game.players[0].isInHand)
        XCTAssertEqual(game.players[0].holeCards, [])
        XCTAssertEqual(game.dealerIndex, 1)
    }
}
