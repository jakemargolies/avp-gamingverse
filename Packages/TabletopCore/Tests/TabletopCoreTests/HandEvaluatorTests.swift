import XCTest
@testable import TabletopCore

final class HandEvaluatorTests: XCTestCase {
    private func hand(_ notation: String) -> EvaluatedHand {
        HandEvaluator.evaluate(notation.split(separator: " ").map { Card(String($0))! })
    }

    func testCategories() {
        XCTAssertEqual(hand("As Ks Qs Js Ts").value.category, .straightFlush)
        XCTAssertEqual(hand("9c 9d 9h 9s 2c").value.category, .fourOfAKind)
        XCTAssertEqual(hand("9c 9d 9h 2s 2c").value.category, .fullHouse)
        XCTAssertEqual(hand("2h 7h 9h Jh Kh").value.category, .flush)
        XCTAssertEqual(hand("5c 6d 7h 8s 9c").value.category, .straight)
        XCTAssertEqual(hand("5c 5d 5h 8s 9c").value.category, .threeOfAKind)
        XCTAssertEqual(hand("5c 5d 8h 8s 9c").value.category, .twoPair)
        XCTAssertEqual(hand("5c 5d 7h 8s 9c").value.category, .onePair)
        XCTAssertEqual(hand("2c 5d 7h 8s 9c").value.category, .highCard)
    }

    func testWheelIsLowestStraight() {
        let wheel = hand("Ac 2d 3h 4s 5c")
        XCTAssertEqual(wheel.value.category, .straight)
        XCTAssertEqual(wheel.value.tiebreakers, [.five])
        XCTAssertLessThan(wheel.value, hand("2d 3h 4s 5c 6d").value)
        XCTAssertEqual(hand("Ah 2h 3h 4h 5h").value.category, .straightFlush)
    }

    func testCategoryOrdering() {
        XCTAssertGreaterThan(hand("2h 7h 9h Jh Kh").value, hand("Tc Jd Qh Ks Ac").value)
        XCTAssertGreaterThan(hand("2c 2d 2h 3s 3c").value, hand("Ah Kh Qh Jh 9h").value)
    }

    func testKickersBreakTies() {
        XCTAssertGreaterThan(hand("Ac Ad Kh 7s 2c").value, hand("Ah As Qh 7d 2d").value)
        XCTAssertEqual(hand("Ac Ad Kh 7s 2c").value, hand("Ah As Kd 7d 2d").value)
    }

    func testPicksBestFiveOfSeven() {
        let fullHouse = hand("Ah Ad Ac Kh Kd Ks 2c")
        XCTAssertEqual(fullHouse.value.category, .fullHouse)
        XCTAssertEqual(fullHouse.value.tiebreakers, [.ace, .king])

        let twoPair = hand("Ah Ad Kh Kd Qh Qd 2c")
        XCTAssertEqual(twoPair.value.category, .twoPair)
        XCTAssertEqual(twoPair.value.tiebreakers, [.ace, .king, .queen])
        XCTAssertEqual(twoPair.bestFive.count, 5)
    }
}
