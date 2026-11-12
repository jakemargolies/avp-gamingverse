import SwiftUI
import TabletopCore

/// A playing card; `nil` shows the back.
struct CardView: View {
    let card: Card?
    var width: CGFloat = 60

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: width * 0.1, style: .continuous)
        Group {
            if let card {
                VStack(spacing: -width * 0.08) {
                    Text(card.rank == .ten ? "10" : card.rank.symbol)
                    Text(card.suit.symbol)
                }
                .font(.system(size: width * 0.42, weight: .bold, design: .rounded))
                .foregroundStyle(card.suit.isRed ? Color.red : Color.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.white, in: shape)
            } else {
                shape
                    .fill(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(shape.inset(by: width * 0.08).stroke(.white.opacity(0.6), lineWidth: 2))
            }
        }
        .frame(width: width, height: width * 1.4)
    }
}

/// Where a card will go but hasn't been dealt yet.
struct CardSlot: View {
    var width: CGFloat = 60

    var body: some View {
        RoundedRectangle(cornerRadius: width * 0.1, style: .continuous)
            .strokeBorder(.white.opacity(0.3), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .frame(width: width, height: width * 1.4)
    }
}

struct DealerButton: View {
    var body: some View {
        Text("D")
            .font(.caption.weight(.heavy))
            .foregroundStyle(.black)
            .frame(width: 26, height: 26)
            .background(.white, in: Circle())
    }
}

/// Community cards and the pot, lying on the middle of the table.
struct BoardView: View {
    let table: HoldemTableModel

    var body: some View {
        let game = table.game
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                ForEach(0..<5, id: \.self) { index in
                    if index < game.community.count {
                        CardView(card: game.community[index], width: 80)
                    } else {
                        CardSlot(width: 80)
                    }
                }
            }
            Text(game.pot > 0 ? "Pot \(game.pot)" : " ")
                .font(.title2.weight(.semibold))
                .monospacedDigit()
        }
        .padding(20)
    }
}

/// A bot's seat: its cards, stack and latest action.
struct SeatView: View {
    let table: HoldemTableModel
    let playerID: PlayerID

    var body: some View {
        let player = table.game.player(playerID)!
        let revealed = table.revealedHand(of: playerID)
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                if player.isLive || revealed != nil {
                    ForEach(0..<player.holeCards.count, id: \.self) { index in
                        CardView(card: revealed == nil ? nil : player.holeCards[index], width: 56)
                    }
                } else {
                    CardSlot(width: 56)
                    CardSlot(width: 56)
                }
            }
            HStack(spacing: 6) {
                if table.isDealer(playerID) { DealerButton() }
                Text(player.name).font(.headline)
            }
            Text("\(player.chips) chips")
                .font(.subheadline)
                .monospacedDigit()
            Text(status(of: player, revealed: revealed))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(table.winnings(of: playerID) != nil ? .yellow : .secondary)
                .lineLimit(1)
        }
        .padding(16)
        .frame(width: 220, height: 230)
        .glassBackgroundEffect()
        .overlay {
            if table.isCurrentPlayer(playerID) {
                RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.yellow, lineWidth: 4)
            }
        }
        .opacity(player.isLive || table.game.phase == .handComplete && player.chips > 0 ? 1 : 0.5)
    }

    private func status(of player: Player, revealed: EvaluatedHand?) -> String {
        if let won = table.winnings(of: playerID) { return "Wins \(won)" }
        if let revealed { return revealed.value.category.name }
        if !player.isInHand && player.chips == 0 { return "Out" }
        if player.isAllIn { return "All in" }
        if let action = table.lastActions[playerID] {
            return action == .call || action == .check ? "\(action.label) · \(player.streetBet)" : action.label
        }
        return player.streetBet > 0 ? "Bet \(player.streetBet)" : " "
    }
}

/// Your hand and the betting controls, floating in front of the table.
struct PlayerControlsView: View {
    let table: HoldemTableModel
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let you = table.human
        HStack(spacing: 28) {
            HStack(spacing: 8) {
                if you.holeCards.isEmpty || you.hasFolded {
                    CardSlot(width: 70)
                    CardSlot(width: 70)
                } else {
                    ForEach(you.holeCards, id: \.self) { CardView(card: $0, width: 70) }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if table.isDealer(HoldemTableModel.humanID) { DealerButton() }
                    Text("You").font(.headline)
                }
                Text("\(you.chips) chips").monospacedDigit()
                if you.streetBet > 0 {
                    Text("Bet \(you.streetBet)").monospacedDigit().foregroundStyle(.secondary)
                }
                if let hand = table.humanHandName {
                    Text(hand).foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 120, alignment: .leading)

            Divider().frame(height: 80)

            controls
                .frame(minWidth: 360)
        }
        .padding(24)
        .glassBackgroundEffect()
    }

    @ViewBuilder private var controls: some View {
        let game = table.game
        if table.isGameOver {
            VStack(spacing: 12) {
                Text(table.human.chips == 0 ? "You're out of chips." : "You won every chip!")
                    .font(.headline)
                Button("New Game") { appModel.startNewGame(botCount: table.botCount) }
            }
        } else if let legal = table.humanLegalActions {
            HStack(spacing: 12) {
                if legal.canCheck {
                    Button("Check") { table.act(.check) }
                } else {
                    Button("Fold") { table.act(.fold) }
                    Button("Call \(legal.callAmount)") { table.act(.call) }
                }
                if let range = legal.raiseRange {
                    RaiseControl(range: range, step: game.bigBlind) { table.act(.raise(to: $0)) }
                        .id(range)
                }
            }
        } else if game.isBetting {
            Text("\(game.currentPlayer?.name ?? "Dealer") is thinking…")
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 12) {
                if let summary = table.resultSummary {
                    Text(summary).multilineTextAlignment(.center)
                }
                Button(game.handNumber == 0 ? "Deal" : "Next Hand") { table.dealNextHand() }
            }
        }
    }
}

private struct RaiseControl: View {
    let range: ClosedRange<Int>
    let step: Int
    let onRaise: (Int) -> Void
    @State private var amount: Double

    init(range: ClosedRange<Int>, step: Int, onRaise: @escaping (Int) -> Void) {
        self.range = range
        self.step = step
        self.onRaise = onRaise
        _amount = State(initialValue: Double(range.lowerBound))
    }

    var body: some View {
        let target = snapped
        HStack(spacing: 12) {
            if range.lowerBound < range.upperBound {
                Slider(value: $amount, in: Double(range.lowerBound)...Double(range.upperBound))
                    .frame(width: 180)
            }
            Button(target == range.upperBound ? "All In \(target)" : "Raise to \(target)") { onRaise(target) }
                .monospacedDigit()
        }
    }

    /// Rounds to the big blind, while still allowing the exact minimum and all-in.
    private var snapped: Int {
        let raw = Int(amount.rounded())
        if raw >= range.upperBound { return range.upperBound }
        return min(max(raw / step * step, range.lowerBound), range.upperBound)
    }
}
