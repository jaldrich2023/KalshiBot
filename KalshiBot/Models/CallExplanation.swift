//
//  CallExplanation.swift
//  KalshiBot
//
//  Plain-language breakdown of why a logged call succeeded or failed.
//

import Foundation

nonisolated struct CallExplanation: Sendable, Equatable {

    enum Outcome: Sendable, Equatable { case correct, wrong, pending }

    struct Point: Sendable, Equatable, Identifiable {
        let title: String
        let detail: String
        /// `true` helped the call, `false` worked against it, nil neutral.
        let helped: Bool?
        var id: String { title }
    }

    let outcome: Outcome
    let headline: String
    let points: [Point]

    struct Inputs: Sendable {
        var predictedUp: Bool
        var probabilityUp: Double
        var callDelaySeconds: TimeInterval
        var strike: Double
        var spotAtCall: Double
        var settlement: Double?
        var actualUp: Bool?
        var kalshiYes: Double?
        var kalshiBid: Double?
        var kalshiAsk: Double?
        /// The head-start feature at the call: (spot − target) / σ of the move still to come.
        var headStart: Double?
        /// Model contributions (log-odds) by indicator title.
        var contributions: [(title: String, value: Double)]
    }

    init(_ input: Inputs) {
        let side = input.predictedUp ? "Up" : "Down"
        let confidence = max(input.probabilityUp, 1 - input.probabilityUp)
        let lead = input.spotAtCall - input.strike
        let leadSide = lead >= 0 ? "above" : "below"
        let minutes = Int((input.callDelaySeconds / 60).rounded())
        var points: [Point] = []

        // 1. Where the price stood when the call was made.
        var leadDetail = "At +\(minutes) min the price was \(BotEngine.usd(abs(lead))) \(leadSide) the \(BotEngine.usd(input.strike)) target."
        if let z = input.headStart {
            let flip = SettlementOdds.calibratedFlip(raw: Indicators.normalCDF(-abs(z)))
            leadDetail += " From there, a reversal happens about \(Self.percent(flip)) of the time."
        }
        points.append(Point(title: "Lead at the call", detail: leadDetail, helped: (lead >= 0) == input.predictedUp ? true : false))

        // 2. What Kalshi thought.
        if let yes = input.kalshiYes {
            let kalshiUp = yes >= 0.5
            var detail = "Kalshi priced Up at \(Self.percent(yes))"
            if let bid = input.kalshiBid, let ask = input.kalshiAsk {
                detail += " (bid \(StrategyAdvisor.cents(bid)) / ask \(StrategyAdvisor.cents(ask)))"
            }
            detail += kalshiUp == input.predictedUp ? " — the same side as the call." : " — the opposite side; the bot disagreed with the market."
            points.append(Point(title: "Kalshi's view", detail: detail, helped: nil))
        }

        // 3. The main model inputs.
        let top = input.contributions.filter { abs($0.value) >= 0.01 }.sorted { abs($0.value) > abs($1.value) }.prefix(3)
        if !top.isEmpty {
            let parts = top.map { "\($0.title) (\($0.value >= 0 ? "Up" : "Down"))" }
            points.append(Point(title: "What drove the call",
                                detail: "\(parts.joined(separator: ", ")). P(up) \(Self.percent(input.probabilityUp)).",
                                helped: nil))
        }

        // 4. What happened after the call.
        guard let settlement = input.settlement, let actualUp = input.actualUp else {
            outcome = .pending
            headline = "Called \(side) at \(Self.percent(confidence)) — not settled yet"
            self.points = points
            return
        }
        let correct = actualUp == input.predictedUp
        let move = settlement - input.spotAtCall
        let margin = settlement - input.strike
        let movedToward = (move >= 0) == input.predictedUp
        points.append(Point(
            title: "After the call",
            detail: "The price moved \(BotEngine.usd(abs(move))) \(move >= 0 ? "up" : "down") and settled at \(BotEngine.usd(settlement)), \(BotEngine.usd(abs(margin))) \(margin >= 0 ? "above" : "below") the target.",
            helped: movedToward))

        // 5. The verdict, in words.
        let leadAgreed = (lead >= 0) == input.predictedUp
        let held = (lead >= 0) == actualUp
        let why: String
        switch (correct, leadAgreed, held) {
        case (true, true, true):
            why = "The lead the call relied on held to the close."
        case (true, false, _):
            why = "The call went against the lead at the time, and the price crossed the target in its favor."
        case (true, true, false):
            why = "Settled on the called side."
        case (false, true, false):
            why = "A reversal: the price was on the called side at +\(minutes) min but crossed the target before settlement."
        case (false, false, _):
            why = "The call went against the lead, and the lead held."
        case (false, true, true):
            why = "Settled against the call."
        }
        let closeCall = abs(margin) < 10 ? " It settled within \(BotEngine.usd(abs(margin))) of the target — a very close finish." : ""
        points.append(Point(title: correct ? "Why it worked" : "Why it missed", detail: why + closeCall, helped: correct))

        outcome = correct ? .correct : .wrong
        headline = "\(correct ? "Correct" : "Wrong"): called \(side) at \(Self.percent(confidence)), settled \(actualUp ? "Up" : "Down")"
        self.points = points
    }

    private static func percent(_ p: Double) -> String {
        p.formatted(.percent.precision(.fractionLength(0)))
    }

    static func == (lhs: CallExplanation, rhs: CallExplanation) -> Bool {
        lhs.outcome == rhs.outcome && lhs.headline == rhs.headline && lhs.points == rhs.points
    }
}

extension CallExplanation {
    init(record r: PredictionRecord) {
        self.init(Inputs(
            predictedUp: r.predictedUp, probabilityUp: r.probabilityUp,
            callDelaySeconds: r.predictedAt.timeIntervalSince(r.openTime),
            strike: r.strike, spotAtCall: r.spotAtPrediction, settlement: r.settlementValue, actualUp: r.actualUp,
            kalshiYes: r.marketYesMid, kalshiBid: r.marketYesBid, kalshiAsk: r.marketYesAsk,
            headStart: r.features[.headStart],
            contributions: r.contributions.map { (title: $0.key.title, value: $0.value) }))
    }
}
