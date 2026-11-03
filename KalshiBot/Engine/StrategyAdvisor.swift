//
//  StrategyAdvisor.swift
//  KalshiBot
//
//  Turns the bot's fair value and Kalshi's live quotes into a recommendation, with
//  entry and exit signals that each carry their justification.
//
//  Grounding: a 60-day backtest found that buying on gaps between a purely statistical
//  fair value and Kalshi's price lost money — Kalshi's price was the better estimate.
//  So fair value here is the trained model, which can only move away from Kalshi's
//  odds after beating them on held-out windows, and an entry needs a clear margin.
//
//  Re-checked Oct 31 against 5,954 windows (60 days): buying Kalshi's favorite at
//  70–85%+ made −0.1 to +0.9¢ per contract at a 1¢ spread and lost at 2¢; stretching
//  Kalshi's odds (a recalibration fitted on the first 30 days) scored worse on the next
//  30; and no indicator predicted Kalshi's misses. Nothing clears fees reliably, so the
//  5¢ margin stays and no time-of-day or calibration adjustments are applied.
//

import Foundation

nonisolated enum KalshiFees {
    /// Kalshi's taker fee per contract: 7% × price × (1 − price), rounded up to the cent.
    static func taker(price: Double) -> Double {
        ((0.07 * price * (1 - price)) * 100).rounded(.up) / 100
    }
}

/// How much risk the recommendations take. None of them has a proven edge: the style
/// changes how readily trades are suggested and how quickly to get out, not the odds.
nonisolated enum TradingStyle: String, CaseIterable, Identifiable, Sendable {
    case conservative, neutral, aggressive

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// Expected profit per contract, after fees, required to suggest an entry.
    var minimumEdge: Double {
        switch self {
        case .conservative: 0.08
        case .neutral: 0.05
        case .aggressive: 0.03
        }
    }
    /// Contract prices an entry may be suggested at (cheap long shots and near-certain
    /// favorites are excluded by the stricter styles).
    var priceRange: ClosedRange<Double> {
        switch self {
        case .conservative: 0.25...0.75
        case .neutral: 0.10...0.90
        case .aggressive: 0.01...0.99
        }
    }
    /// No new entries with less than this left.
    var entryCutoff: TimeInterval {
        switch self {
        case .conservative: 300
        case .neutral: 120
        case .aggressive: 60
        }
    }
    /// Suggest exiting a side once its chance of losing (from the current price) reaches this.
    var exitRisk: Double {
        switch self {
        case .conservative: 0.25
        case .neutral: 0.35
        case .aggressive: 0.50
        }
    }
    /// Suggest taking profit once a side's bid reaches this (nil: hold to settlement).
    var takeProfit: Double? {
        switch self {
        case .conservative: 0.90
        case .neutral: 0.95
        case .aggressive: nil
        }
    }

    /// Stop-loss: exit before selling returns less than (1 − this) of the price paid.
    var maxLoss: Double {
        switch self {
        case .conservative: 0.30
        case .neutral: 0.50
        case .aggressive: 0.70
        }
    }
    /// Take-profit: sell once this share of the most selling could return is locked in.
    var profitCapture: Double {
        switch self {
        case .conservative: 0.60
        case .neutral: 0.80
        case .aggressive: 0.95
        }
    }
    /// Trailing stop: once in profit, keep at least this share of the best gain so far.
    var trailKeep: Double {
        switch self {
        case .conservative: 0.60
        case .neutral: 0.50
        case .aggressive: 0.30
        }
    }

    var summary: String {
        let range = "\(StrategyAdvisor.cents(priceRange.lowerBound))–\(StrategyAdvisor.cents(priceRange.upperBound))"
        let profit = takeProfit.map { "take profit at \(StrategyAdvisor.cents($0))" } ?? "hold winners to settlement"
        return "Enters at \(StrategyAdvisor.cents(minimumEdge))+ expected edge, prices \(range), until \(Int(entryCutoff / 60)) min left. Exits at \(Int(exitRisk * 100))% reversal risk; \(profit)."
    }
}

/// Where to exit the bot's called position: a stop-loss to limit the loss if the call is
/// going wrong, and a take-profit to lock in most of the gain if it's going right — as BTC
/// prices, from what selling would actually return at each price.
///
/// Selling value at a BTC price x = the called side's calibrated chance of winning at x
/// (current volatility, time left, settlement minute), shifted by how Kalshi prices that
/// side relative to those odds right now, minus half the current spread and Kalshi's fee.
/// With Kalshi's price as fair, exiting doesn't raise expected profit; it caps the loss,
/// locks in gains, and removes late-reversal risk.
nonisolated struct ExitPlan: Sendable, Equatable {
    /// The called side: `true` = Yes (Up).
    let calledUp: Bool
    /// Price paid per contract at the call.
    let entry: Double
    /// What selling would return right now, after the fee.
    let saleNow: Double
    /// BTC price at which to cut the loss, and what selling would return there.
    let stop: Double?
    let stopSale: Double
    /// `true` when the stop has been raised to protect gains made earlier in the window.
    let stopIsTrailing: Bool
    /// BTC price at which to take profit, and what selling would return there.
    let takeProfit: Double?
    let takeProfitSale: Double
    /// The take-profit target is above the most a contract can sell for, so there's no line.
    var takeProfitUnreachable = false

    /// Already past the stop: selling now loses less than the stop allows for.
    var exitNow: Bool { saleNow <= stopSale }

    struct Market: Sendable {
        var strike: Double
        var price: Double
        var secondsRemaining: TimeInterval
        /// Dollars per √second.
        var volatility: Double
        var settlementAverageSoFar: Double?
        var yesBid: Double
        var yesAsk: Double
    }

    /// What selling the called side returns if BTC is at `x`, with `seconds` left.
    static func sale(at x: Double, seconds: TimeInterval, calledUp: Bool, market m: Market) -> Double {
        func sideOdds(_ price: Double, _ seconds: TimeInterval) -> Double {
            let up = SettlementOdds.estimate(price: price, strike: m.strike, secondsRemaining: seconds,
                                             volatility: m.volatility, settlementAverageSoFar: m.settlementAverageSoFar).probabilityUp
            return calledUp ? up : 1 - up
        }
        // How Kalshi prices the side right now relative to the bot's odds, and its spread.
        let sideMid = calledUp ? (m.yesBid + m.yesAsk) / 2 : 1 - (m.yesBid + m.yesAsk) / 2
        let gap = sideMid - sideOdds(m.price, m.secondsRemaining)
        let halfSpread = max(m.yesAsk - m.yesBid, 0.01) / 2
        let bid = min(max(sideOdds(x, seconds) + gap - halfSpread, 0.01), 0.99)
        return bid - KalshiFees.taker(price: bid)
    }

    /// - Parameters:
    ///   - peakSale: the best selling value seen since the call, for the trailing stop.
    ///   - maxLoss: share of the stake to risk before the stop (overrides the style's default).
    ///   - takeProfitGain: gain on the stake to take profit at (overrides the style's default).
    static func compute(calledUp: Bool, entry: Double, market m: Market, peakSale: Double?, style: TradingStyle,
                        maxLoss: Double? = nil, takeProfitGain: Double? = nil) -> ExitPlan? {
        guard m.volatility > 0, m.secondsRemaining > 0, entry > 0, entry < 1 else { return nil }
        let saleNow = sale(at: m.price, seconds: m.secondsRemaining, calledUp: calledUp, market: m)

        // Loss stop: give back at most the style's share of the stake.
        var stopTarget = entry * (1 - (maxLoss ?? style.maxLoss))
        var trailing = false
        let maxSale = 0.99 - KalshiFees.taker(price: 0.99)
        // Trailing: once the position has made a real gain, keep at least the style's share of
        // the best gain so far. Switching on at any gain put the stop right at the price (half
        // of a sub-cent gain ≈ break-even), so ordinary noise read as "exit now" on a winning
        // call; now it waits for 10¢ a contract or a quarter of the most it could still gain.
        if let peak = peakSale, peak - entry >= trailActivation(entry: entry, maxSale: maxSale) {
            let protected = entry + style.trailKeep * (peak - entry)
            if protected > stopTarget { stopTarget = protected; trailing = true }
        }
        // Take profit: a set gain on the stake if chosen, else the style's share of the most
        // selling could ever return.
        let profitTarget = takeProfitGain.map { entry * (1 + $0) } ?? entry + style.profitCapture * max(maxSale - entry, 0)
        let unreachable = profitTarget > maxSale

        return ExitPlan(calledUp: calledUp, entry: entry, saleNow: saleNow,
                        stop: level(for: stopTarget, calledUp: calledUp, market: m), stopSale: stopTarget,
                        stopIsTrailing: trailing,
                        takeProfit: !unreachable && profitTarget > saleNow ? level(for: profitTarget, calledUp: calledUp, market: m) : nil,
                        takeProfitSale: profitTarget, takeProfitUnreachable: unreachable)
    }

    /// Gain per contract the position must reach before the stop starts trailing.
    static func trailActivation(entry: Double, maxSale: Double) -> Double {
        max(0.10, 0.25 * max(maxSale - entry, 0))
    }

    /// The BTC price at which selling returns `target`, by bisection (selling value rises
    /// with price for Yes and falls for No). Nil if no price in range reaches it.
    static func level(for target: Double, calledUp: Bool, market m: Market) -> Double? {
        let span = max(m.volatility * m.secondsRemaining.squareRoot() * 12, 200)
        var low = m.strike - span, high = m.strike + span
        func value(_ x: Double) -> Double {
            let v = sale(at: x, seconds: m.secondsRemaining, calledUp: calledUp, market: m)
            return calledUp ? v : -v   // make it increasing in x either way
        }
        let goal = calledUp ? target : -target
        guard value(low) < goal, value(high) > goal else { return nil }
        for _ in 0..<60 {
            let mid = (low + high) / 2
            if value(mid) < goal { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }
}

/// Dollar profit and loss for a stake placed on the bot's call, from the window's state now.
nonisolated struct PositionEstimate: Sendable, Equatable {
    let contracts: Int
    let entry: Double
    /// What the contracts cost, fees included.
    let cost: Double
    /// Selling everything now.
    let saleNow: Double
    var profitNow: Double { saleNow - cost }
    /// Settling on the called side pays $1 a contract; the other side pays nothing.
    var profitIfRight: Double { Double(contracts) - cost }
    var profitIfWrong: Double { -cost }
    /// Kalshi's current chance for the called side, and the expected result at settlement.
    let chanceRight: Double
    var expectedProfit: Double { chanceRight * Double(contracts) - cost }
    /// Selling at the chart's stop-loss and take-profit lines.
    let profitAtStop: Double?
    let profitAtTakeProfit: Double?

    /// - Parameters:
    ///   - stake: dollars to put on the call.
    ///   - chanceRight: probability the called side settles in the money (Kalshi's mid for it).
    static func estimate(stake: Double, plan: ExitPlan, chanceRight: Double) -> PositionEstimate? {
        let perContract = plan.entry + KalshiFees.taker(price: plan.entry)
        guard stake > 0, perContract > 0 else { return nil }
        let contracts = Int((stake / perContract).rounded(.down))
        guard contracts > 0 else { return nil }
        let n = Double(contracts)
        let cost = n * perContract
        return PositionEstimate(contracts: contracts, entry: plan.entry, cost: cost, saleNow: n * plan.saleNow,
                                chanceRight: chanceRight,
                                profitAtStop: plan.stop.map { _ in n * plan.stopSale - cost },
                                profitAtTakeProfit: plan.takeProfit.map { _ in n * plan.takeProfitSale - cost })
    }
}

nonisolated struct StrategySignal: Sendable, Equatable, Identifiable {
    enum Kind: String, Sendable { case entry, exit }
    let kind: Kind
    /// `true` = the Yes (Up) side, `false` = the No (Down) side.
    let isYes: Bool
    let title: String
    let justification: String
    /// Distinguishes exits for different reasons on the same side.
    var reason: String = ""
    var id: String { "\(kind.rawValue)-\(isYes)\(reason.isEmpty ? "" : "-\(reason)")" }
}

nonisolated struct StrategyAdvice: Sendable, Equatable {
    enum Action: Sendable, Equatable { case buyYes, buyNo, standAside }

    let action: Action
    let headline: String
    let justification: String
    /// Fair value of Up (the trained model on live data).
    let fairUp: Double
    let yesBid: Double?
    let yesAsk: Double?
    /// Expected profit per contract from buying each side now, after the taker fee.
    let edgeYes: Double?
    let edgeNo: Double?
    /// Entry and exit conditions that hold right now.
    let signals: [StrategySignal]
}

nonisolated enum StrategyAdvisor {

    /// The neutral style's entry margin, for text that doesn't know the chosen style.
    static let minimumEdge = TradingStyle.neutral.minimumEdge

    /// - Parameter priceOddsUp: calibrated P(up) from the current price (`SettlementOdds`),
    ///   used for the reversal-risk exits; nil skips them.
    /// - Parameter calledUp: the bot's locked call for the window, if made. Entries are only
    ///   suggested on that side, so the recommendation never contradicts the prediction.
    static func advise(fairUp: Double, yesBid: Double?, yesAsk: Double?, secondsRemaining: TimeInterval,
                       style: TradingStyle = .neutral, priceOddsUp: Double? = nil, calledUp: Bool? = nil) -> StrategyAdvice {
        guard let yesBid, let yesAsk, yesBid > 0, yesAsk < 1, yesAsk >= yesBid else {
            return StrategyAdvice(action: .standAside, headline: "Stand aside",
                                  justification: "Kalshi has no two-sided quote for this window right now.",
                                  fairUp: fairUp, yesBid: yesBid, yesAsk: yesAsk, edgeYes: nil, edgeNo: nil, signals: [])
        }
        // Buying No costs 1 − (best Yes bid); selling No returns 1 − (best Yes ask).
        let noAsk = 1 - yesBid, noBid = 1 - yesAsk
        let fairDown = 1 - fairUp
        let edgeYes = fairUp - yesAsk - KalshiFees.taker(price: yesAsk)
        let edgeNo = fairDown - noAsk - KalshiFees.taker(price: noAsk)

        var signals: [StrategySignal] = []
        let canEnter = secondsRemaining >= style.entryCutoff
        let margin = style.minimumEdge

        if canEnter, edgeYes >= margin, style.priceRange.contains(yesAsk) {
            signals.append(StrategySignal(kind: .entry, isYes: true, title: "Enter: buy Yes at \(cents(yesAsk))",
                justification: "Fair value of Up is \(percent(fairUp)) against a Yes ask of \(cents(yesAsk)) plus a \(cents(KalshiFees.taker(price: yesAsk))) fee — an expected \(signedCents(edgeYes)) per contract, above the \(cents(margin)) \(style.title.lowercased()) margin."))
        }
        if canEnter, edgeNo >= margin, style.priceRange.contains(noAsk) {
            signals.append(StrategySignal(kind: .entry, isYes: false, title: "Enter: buy No at \(cents(noAsk))",
                justification: "Fair value of Down is \(percent(fairDown)) against a No ask of \(cents(noAsk)) plus a \(cents(KalshiFees.taker(price: noAsk))) fee — an expected \(signedCents(edgeNo)) per contract, above the \(cents(margin)) \(style.title.lowercased()) margin."))
        }

        // Exit when selling is worth at least as much as holding: it locks in the value
        // and removes the risk of the window turning.
        let sellYes = yesBid - KalshiFees.taker(price: yesBid)
        if sellYes >= fairUp {
            signals.append(StrategySignal(kind: .exit, isYes: true, title: "If holding Yes: sell at \(cents(yesBid))",
                justification: "Selling returns \(cents(sellYes)) after the fee, at least the \(cents(fairUp)) expected by holding to settlement — the same value or better, with no risk."))
        }
        let sellNo = noBid - KalshiFees.taker(price: noBid)
        if sellNo >= fairDown {
            signals.append(StrategySignal(kind: .exit, isYes: false, title: "If holding No: sell at \(cents(noBid))",
                justification: "Selling returns \(cents(sellNo)) after the fee, at least the \(cents(fairDown)) expected by holding to settlement — the same value or better, with no risk."))
        }

        // Style exits: reversal risk from the current price, and take-profit.
        for isYes in [true, false] {
            let bid = isYes ? yesBid : noBid
            let side = isYes ? "Yes" : "No"
            if let up = priceOddsUp {
                let loses = isYes ? 1 - up : up
                if loses >= style.exitRisk {
                    signals.append(StrategySignal(kind: .exit, isYes: isYes, title: "If holding \(side): exit at \(cents(bid))",
                        justification: "From the current price, \(side) now loses \(percent(loses)) of the time — at or above the \(percent(style.exitRisk)) reversal risk the \(style.title.lowercased()) style accepts. Selling returns \(cents(bid - KalshiFees.taker(price: bid))) after the fee.",
                        reason: "risk"))
                }
            }
            if let target = style.takeProfit, bid >= target {
                signals.append(StrategySignal(kind: .exit, isYes: isYes, title: "If holding \(side): take profit at \(cents(bid))",
                    justification: "The \(side) bid reached \(cents(bid)), the \(cents(target)) take-profit level for the \(style.title.lowercased()) style — locking it in gives up at most \(cents(1 - bid)) of upside to remove the reversal risk.",
                    reason: "profit"))
            }
        }

        // Drop entries against the locked call; remember one so the reason can be shown.
        var againstCall: StrategySignal?
        if let calledUp {
            againstCall = signals.first { $0.kind == .entry && $0.isYes != calledUp }
            signals.removeAll { $0.kind == .entry && $0.isYes != calledUp }
        }

        let action: StrategyAdvice.Action
        let headline: String
        let justification: String
        if let entry = signals.first(where: { $0.kind == .entry }) {
            action = entry.isYes ? .buyYes : .buyNo
            headline = entry.isYes ? "Buy Yes (Up)" : "Buy No (Down)"
            justification = entry.justification
        } else if let against = againstCall, let calledUp {
            let call = calledUp ? "Up" : "Down", other = calledUp ? "Down" : "Up"
            action = .standAside
            headline = "Stand aside — against the call"
            justification = "The call is \(call), but fair value now leans \(other) (\(percent(fairUp)) Up) — \(against.title.lowercased()) would trade against the bot's own prediction, so it's not recommended. If fair value ignores Kalshi's price (“Use Kalshi odds” unchecked), gaps like this are usually the model's error."
        } else if !canEnter {
            action = .standAside
            headline = "Stand aside"
            justification = "Under \(Int(style.entryCutoff / 60)) min left — past the \(style.title.lowercased()) style's entry cutoff."
        } else {
            action = .standAside
            headline = "Stand aside — no edge"
            let best = max(edgeYes, edgeNo)
            justification = "The bot's fair value of Up (\(percent(fairUp))) is close to Kalshi's price (Yes \(cents(yesBid))/\(cents(yesAsk))). After the spread and fee, the best trade is worth \(signedCents(best)) per contract — short of the \(cents(margin)) \(style.title.lowercased()) margin. In a 60-day backtest, trading such small gaps lost money."
        }
        return StrategyAdvice(action: action, headline: headline, justification: justification, fairUp: fairUp,
                              yesBid: yesBid, yesAsk: yesAsk, edgeYes: edgeYes, edgeNo: edgeNo, signals: signals)
    }

    static func cents(_ dollars: Double) -> String {
        "\((dollars * 100).formatted(.number.precision(.fractionLength(0))))¢"
    }

    static func signedCents(_ dollars: Double) -> String {
        "\(dollars >= 0 ? "+" : "−")\((abs(dollars) * 100).formatted(.number.precision(.fractionLength(1))))¢"
    }

    private static func percent(_ p: Double) -> String {
        p.formatted(.percent.precision(.fractionLength(0)))
    }
}
