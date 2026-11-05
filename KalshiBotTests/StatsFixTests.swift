//
//  StatsFixTests.swift
//  KalshiBotTests
//
//  Significance of the edge over Kalshi, accuracy intervals, Brier verdicts, and
//  formatting of values that round to zero.
//

import Foundation
import Testing
@testable import KalshiBot

struct EdgeSignificanceTests {

    /// `botWins` windows where only the bot was right, `kalshiWins` where only Kalshi was,
    /// and `agreed` where both called it right.
    func stats(botWins: Int, kalshiWins: Int = 0, agreed: Int = 0) -> AccuracyStats {
        AccuracyStats(
            Array(repeating: AccuracyStats.Outcome(probabilityUp: 0.6, actualUp: true, marketYesMid: 0.4), count: botWins)
            + Array(repeating: .init(probabilityUp: 0.4, actualUp: true, marketYesMid: 0.6), count: kalshiWins)
            + Array(repeating: .init(probabilityUp: 0.6, actualUp: true, marketYesMid: 0.6), count: agreed))
    }

    @Test func twoOfTwoIsNotSignificant() throws {
        // Both paired differences are +1, so their spread is 0 — the old margin was 0 too.
        let edge = try #require(stats(botWins: 2).edgeVsMarket)
        #expect(edge.accuracy == 1)
        #expect(!edge.isSignificant)
        #expect(abs(edge.accuracyPValue - 0.5) < 1e-12)
    }

    @Test func smallLopsidedSplitsAreNotSignificant() throws {
        let four = try #require(stats(botWins: 4).edgeVsMarket)
        #expect(abs(four.accuracyPValue - 0.125) < 1e-12)
        #expect(!four.isSignificant)
        let five = try #require(stats(botWins: 5, agreed: 20).edgeVsMarket)
        #expect(abs(five.accuracyPValue - 0.0625) < 1e-12)
        #expect(!five.isSignificant)
    }

    @Test func sixOfSixIsSignificantEitherWay() throws {
        let bot = try #require(stats(botWins: 6, agreed: 10).edgeVsMarket)
        #expect(abs(bot.accuracyPValue - 2.0 / 64) < 1e-12)
        #expect(bot.isSignificant && bot.accuracy > 0)
        let kalshi = try #require(stats(botWins: 0, kalshiWins: 6).edgeVsMarket)
        #expect(kalshi.isSignificant && kalshi.accuracy < 0)
    }

    @Test func evenSplitsAndNoDisagreementsAreNeverSignificant() throws {
        #expect(AccuracyStats.signTestPValue(0, 0) == 1)
        #expect(AccuracyStats.signTestPValue(3, 3) == 1)
        let agreed = try #require(stats(botWins: 0, agreed: 50).edgeVsMarket)
        #expect(agreed.disagreements == 0 && !agreed.isSignificant)
    }

    @Test func signTestHandlesManyDisagreements() {
        // 600 of 1,000 is far beyond chance; 510 of 1,000 is not.
        #expect(AccuracyStats.signTestPValue(600, 400) < 1e-9)
        #expect(AccuracyStats.signTestPValue(510, 490) > 0.5)
    }

    @Test func marginIsNeverZeroWithDisagreements() throws {
        for (b, c, agreed) in [(2, 0, 0), (1, 0, 30), (3, 3, 0), (6, 0, 10)] {
            let edge = try #require(stats(botWins: b, kalshiWins: c, agreed: agreed).edgeVsMarket)
            #expect(edge.accuracyMargin >= 1.96 * Double(b + c).squareRoot() / Double(edge.windows) - 1e-12)
            #expect(edge.accuracyMargin > 0)
        }
    }
}

struct AccuracyIntervalTests {

    func stats(correct: Int, of total: Int) -> AccuracyStats {
        AccuracyStats((0..<total).map { .init(probabilityUp: 0.6, actualUp: $0 < correct, marketYesMid: nil) })
    }

    @Test func wilsonIntervalStaysWithinZeroAndOne() {
        for (k, n) in [(0, 1), (1, 1), (0, 5), (5, 5), (10, 10), (3, 7), (999, 1000)] {
            let interval = AccuracyStats.wilsonInterval(successes: k, total: n)
            #expect(interval.lowerBound >= 0 && interval.upperBound <= 1, "\(k)/\(n)")
            #expect(interval.contains(Double(k) / Double(n)), "\(k)/\(n)")
        }
    }

    @Test func wilsonIntervalIsNotZeroWidthAtTheExtremes() throws {
        let perfect = try #require(stats(correct: 10, of: 10).accuracyInterval)
        #expect(perfect.upperBound > 1 - 1e-12 && perfect.lowerBound < 0.8)
        #expect(try #require(stats(correct: 10, of: 10).accuracyMargin) > 0)
        #expect(try #require(stats(correct: 1, of: 1).accuracyMargin) > 0)
        #expect(try #require(stats(correct: 0, of: 4).accuracyInterval).lowerBound < 1e-12)
        #expect(stats(correct: 0, of: 0).accuracyMargin == nil)
    }

    @Test func wilsonMatchesAKnownValue() {
        // 7 of 10: Wilson 95% interval ≈ 0.3968–0.8922.
        let interval = AccuracyStats.wilsonInterval(successes: 7, total: 10)
        #expect(abs(interval.lowerBound - 0.3968) < 1e-3)
        #expect(abs(interval.upperBound - 0.8922) < 1e-3)
    }
}

struct BrierSignificanceTests {
    let start = Date(timeIntervalSince1970: 1_793_160_000)

    /// `count` windows where the bot was a little closer than Kalshi, plus `even` where it
    /// quoted Kalshi's price exactly.
    func windows(_ count: Int, even: Int = 0) -> [PerformanceBreakdown.Window] {
        (0..<(count + even)).map { i in
            .init(openTime: start.addingTimeInterval(Double(i) * 900),
                  probabilityUp: i < count ? 0.6 : 0.55, marketYesMid: 0.55, actualUp: true)
        }
    }

    @Test func tCriticalValues() {
        #expect(AccuracyStats.tCritical95(degreesOfFreedom: 1) == 12.706)
        #expect(AccuracyStats.tCritical95(degreesOfFreedom: 9) == 2.262)
        #expect(AccuracyStats.tCritical95(degreesOfFreedom: 30) == 2.042)
        #expect(AccuracyStats.tCritical95(degreesOfFreedom: 31) == 1.96)
        #expect(AccuracyStats.tCritical95(degreesOfFreedom: 0) == .infinity)
    }

    @Test func smallSamplesUseTheWiderTMargin() {
        let (_, margin) = AccuracyStats.meanAndMargin([0.01, 0.03, 0.02, 0.04, 0.0])
        let sd = ([0.01, 0.03, 0.02, 0.04, 0.0].map { ($0 - 0.02) * ($0 - 0.02) }.reduce(0, +) / 4).squareRoot()
        #expect(abs(margin - 2.776 * sd / 5.0.squareRoot()) < 1e-12)
    }

    @Test func periodNeedsTenWindowsThatDiffer() {
        // Every edge identical, so the spread (and margin) is 0: only the count protects it.
        #expect(!PerformanceBreakdown.period(windows(9), id: "x", label: "x").isSignificant)
        #expect(PerformanceBreakdown.period(windows(10), id: "x", label: "x").isSignificant)
        // Plenty of windows, but only 3 that differ from Kalshi at all.
        let mostlyEven = PerformanceBreakdown.period(windows(3, even: 60), id: "x", label: "x")
        #expect(mostlyEven.unevenWindows == 3)
        #expect(!mostlyEven.isSignificant)
    }

    @Test func accuracyStatsBrierNeedsTenWindowsThatDiffer() throws {
        func outcomes(_ n: Int) -> [AccuracyStats.Outcome] {
            (0..<n).map { _ in .init(probabilityUp: 0.6, actualUp: true, marketYesMid: 0.55) }
        }
        let nine = try #require(AccuracyStats(outcomes(9)).edgeVsMarket)
        #expect(nine.brierPairs == 9 && !nine.isBrierSignificant)
        #expect(try #require(AccuracyStats(outcomes(10)).edgeVsMarket).isBrierSignificant)
    }

    @Test func singleWindowHasNoFiniteMargin() {
        #expect(PerformanceBreakdown.period(windows(1), id: "x", label: "x").edgeMargin == .infinity)
    }
}

struct BrierVerdictTests {
    let start = Date(timeIntervalSince1970: 1_793_160_000)

    func window(_ i: Int, bot: Double, market: Double, up: Bool) -> PerformanceBreakdown.Window {
        .init(openTime: start.addingTimeInterval(Double(i) * 900), probabilityUp: bot, marketYesMid: market, actualUp: up)
    }

    @Test func verdictFollowsTheBrierEdgeNotTheCorrectCount() {
        // The bot gets one more call right, but its confident miss leaves it further from
        // the outcomes overall: the edge is negative, so it trailed.
        let p = PerformanceBreakdown.period([window(0, bot: 0.51, market: 0.49, up: true),
                                             window(1, bot: 0.9, market: 0.6, up: false)], id: "x", label: "x")
        #expect(p.botCorrect > p.marketCorrect)
        #expect(p.edge < 0)
        #expect(p.verdict == .behind)
    }

    @Test func edgeThatRoundsToZeroIsEven() {
        // −0.001 points: shown as 0.00, so even rather than behind.
        let p = PerformanceBreakdown.period([window(0, bot: 0.5, market: 0.50001, up: true)], id: "x", label: "x")
        #expect(p.edge < 0)
        #expect(p.verdict == .even)
        #expect(PerformanceBreakdown.points(p.edge) == PerformanceBreakdown.magnitude(0))
    }
}

struct RoundedSignTests {
    let zero = 0.0.formatted(.number.precision(.fractionLength(2)))

    @Test func edgePointsRoundBeforeTakingTheSign() {
        #expect(PerformanceBreakdown.points(-0.00004) == zero)
        #expect(PerformanceBreakdown.points(0.00004) == zero)
        #expect(PerformanceBreakdown.magnitude(-0.00004) == zero)
        #expect(PerformanceBreakdown.points(0.0012) == "+" + 0.12.formatted(.number.precision(.fractionLength(2))))
        #expect(PerformanceBreakdown.points(-0.0012) == "−" + 0.12.formatted(.number.precision(.fractionLength(2))))
        #expect(PerformanceBreakdown.hundredthsOfPoints(-0.00004).sign == .plus)
    }

    @Test func dollarsRoundToTheCentBeforeTakingTheSign() {
        #expect(WindowChart.centsRounded(-0.004) == 0)
        #expect(WindowChart.centsRounded(-0.004).sign == .plus)  // no "-$0.00"
        #expect(WindowChart.centsRounded(-0.006) == -0.01)
        #expect(WindowChart.centsRounded(12.346) == 12.35)
    }
}

struct SemanticVersionNumericTests {

    @Test func hyphenatedIdentifiersAreAlphanumeric() throws {
        // "-1" is a valid alphanumeric identifier, not the number −1: it sorts after any
        // numeric identifier, and by ASCII among alphanumerics ("-" before letters).
        let numeric = try #require(SemanticVersion("1.0.0-alpha.1"))
        let hyphen = try #require(SemanticVersion("1.0.0-alpha.-1"))
        let letters = try #require(SemanticVersion("1.0.0-alpha.a"))
        #expect(numeric < hyphen)
        #expect(!(hyphen < numeric))
        #expect(hyphen < letters)
        #expect(try #require(SemanticVersion("1.0.0-0")) < #require(SemanticVersion("1.0.0--1")))
    }
}
