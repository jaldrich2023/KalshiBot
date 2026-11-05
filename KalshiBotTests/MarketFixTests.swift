//
//  MarketFixTests.swift
//  KalshiBotTests
//
//  Order-level fees, order-book sides, pagination, history decoding, live volatility,
//  the trailing average after a gap and the reversal-risk calibration inputs. No network.
//

import Foundation
import Testing
@testable import KalshiBot

struct OrderFeeTests {
    @Test func feeIsRoundedOncePerOrder() {
        #expect(KalshiFees.taker(price: 0.5, contracts: 100) == 1.75)    // not 100 × 2¢
        #expect(KalshiFees.taker(price: 0.3, contracts: 10) == 0.15)     // 0.147 → 15¢
        #expect(KalshiFees.taker(price: 0.5, contracts: 0) == 0)
    }

    @Test func oneContractMatchesThePerContractFee() {
        for cents in 1...99 {
            let price = Double(cents) / 100
            #expect(KalshiFees.taker(price: price, contracts: 1) == KalshiFees.taker(price: price))
        }
    }

    private var plan: ExitPlan {
        get throws {
            let up = SettlementOdds.estimate(price: 80_010, strike: 80_000, secondsRemaining: 480, volatility: 1.5).probabilityUp
            let m = ExitPlan.Market(strike: 80_000, price: 80_010, secondsRemaining: 480, volatility: 1.5,
                                    yesBid: up - 0.01, yesAsk: up + 0.01)
            return try #require(ExitPlan.compute(calledUp: true, entry: 0.60, market: m, peakSale: nil, style: .neutral))
        }
    }

    @Test func positionCostIncludingTheOrderFeeFitsTheStake() throws {
        let plan = try plan
        let p = try #require(PositionEstimate.estimate(stake: 100, plan: plan, chanceRight: 0.62))
        // 162 × 60¢ = $97.20 + ⌈0.07 × 162 × 0.24⌉ = $2.73 → $99.93; 163 would cost $100.54.
        #expect(p.contracts == 162)
        #expect(abs(p.cost - 99.93) < 1e-9)
        #expect(p.cost <= 100)
        // Selling is one order too.
        let bid = try #require(plan.bidNow)
        #expect(abs(p.saleNow - (162 * bid - KalshiFees.taker(price: bid, contracts: 162))) < 1e-9)
        #expect(abs(p.profitIfRight - (162 - p.cost)) < 1e-9)
    }

    @Test func aStakeJustUnderOneContractBuysNothing() throws {
        let plan = try plan
        // One contract: 60¢ + ⌈1.68¢⌉ = 62¢.
        #expect(PositionEstimate.estimate(stake: 0.61, plan: plan, chanceRight: 0.62) == nil)
        #expect(PositionEstimate.estimate(stake: 0.62, plan: plan, chanceRight: 0.62)?.contracts == 1)
    }
}

struct KalshiPaginationTests {
    @Test func cursorIsPercentEncodedAndRoundTrips() throws {
        let cursor = "a+b/c="
        #expect(KalshiClient.queryEscaped(cursor) == "a%2Bb%2Fc%3D")
        let url = KalshiClient.url("https://example.com/markets", query: ["series_ticker": "KXBTC15M", "cursor": cursor])
        let items = try #require(URLComponents(string: url)?.queryItems)
        #expect(items.first { $0.name == "cursor" }?.value == cursor)
        #expect(items.first { $0.name == "series_ticker" }?.value == "KXBTC15M")
    }

    @Test func emptyValuesAreLeftOut() {
        #expect(KalshiClient.url("https://example.com/markets", query: ["limit": "200", "cursor": ""])
                == "https://example.com/markets?limit=200")
    }

    @Test func aRepeatedCursorEndsPagination() {
        var seen = Set<String>()
        #expect(KalshiClient.nextCursor("abc", pageEmpty: false, seen: &seen) == "abc")
        #expect(KalshiClient.nextCursor("def", pageEmpty: false, seen: &seen) == "def")
        #expect(KalshiClient.nextCursor("abc", pageEmpty: false, seen: &seen) == nil)
        #expect(KalshiClient.nextCursor("ghi", pageEmpty: true, seen: &seen) == nil)
        #expect(KalshiClient.nextCursor(nil, pageEmpty: false, seen: &seen) == nil)
        #expect(KalshiClient.nextCursor("", pageEmpty: false, seen: &seen) == nil)
    }
}

struct OrderBookSideTests {
    private func market(closingAt close: String = "2026-10-27T03:00:00Z") throws -> KalshiMarket {
        let json = """
        {"ticker":"KXBTC15M-26OCT262300-00","status":"active","open_time":"2026-10-27T02:45:00Z",
         "close_time":"\(close)","yes_bid_dollars":"0.4000","yes_ask_dollars":"0.4400"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(KalshiMarket.self, from: Data(json.utf8))
    }

    @Test func anEmptySideOfAFetchedBookIsNoQuote() throws {
        let book = try KalshiClient.topOfBook(from: Data(#"{"orderbook_fp":{"no_dollars":[["0.4200","10.00"]]}}"#.utf8))
        #expect(book.yesBid == .empty)
        #expect(abs(try #require(book.yesAsk.price) - 0.58) < 1e-9)

        var market = try market()
        #expect(market.yesBid == 0.40)                 // no book yet: the market endpoint's quote
        market.liveYesBid = book.yesBid
        market.liveYesAsk = book.yesAsk
        #expect(market.yesBid == nil)                  // book read, no Yes bids: not the stale 40¢
        #expect(abs(try #require(market.yesAsk) - 0.58) < 1e-9)
        #expect(market.yesMid == nil)
    }

    @Test func nullSidesAreEmpty() throws {
        let book = try KalshiClient.topOfBook(from: Data(#"{"orderbook_fp":{"yes_dollars":null,"no_dollars":null}}"#.utf8))
        #expect(book.yesBid == .empty && book.yesAsk == .empty)
    }

    @Test func marketIsMatchedByCloseTime() throws {
        let close = try #require(ISO8601DateFormatter().date(from: "2026-11-01T06:15:00Z"))
        let first = try market(closingAt: "2026-11-01T05:15:00Z"), second = try market(closingAt: "2026-11-01T06:15:00Z")
        #expect(KalshiClient.matching([first, second], closingAt: close)?.closeTime == close)
        #expect(KalshiClient.matching([first], closingAt: close) == nil)
    }
}

struct CandleHistoryDecodingTests {
    @Test func aCandleMissingAQuoteIsSkippedNotTheBatch() throws {
        let json = """
        {"markets":[{"market_ticker":"T","candlesticks":[
          {"end_period_ts":1060,"yes_ask":{"close_dollars":"0.55"}},
          {"end_period_ts":1120,"yes_bid":{"close_dollars":"0.40"},"yes_ask":{"close_dollars":"0.42"}}]}]}
        """
        let mids = try KalshiClient.yesMids(fromCandlesticks: Data(json.utf8), opens: ["T": 1000], offsets: [60, 120])
        #expect(mids[60]?["T"] == nil)
        #expect(abs(try #require(mids[120]?["T"]) - 0.41) < 1e-9)
    }
}

struct LiveVolatilityTests {
    private func candles(minutes: Range<Int>, from start: Double) -> [Candle] {
        minutes.enumerated().map { i, minute in
            let close = start + (i.isMultiple(of: 2) ? 5 : -5)
            return Candle(time: Date(timeIntervalSince1970: Double(minute) * 60), open: close, high: close, low: close,
                          close: close, volume: 1)
        }
    }

    @Test func aMissingStretchIsNotReadAsOneMinute() throws {
        // 40 minutes, a 20-minute gap during which the price moved $500, then 41 minutes.
        let all = candles(minutes: 0..<40, from: 80_000) + candles(minutes: 60..<101, from: 80_500)
        let tail = Array(all.suffix(41))
        let live = try #require(RiskCalibration.volatility(candles: all, halfLife: nil))
        let unbroken = try #require(RiskCalibration.volatility(closes: tail.map(\.close), halfLife: nil))
        let naive = try #require(RiskCalibration.volatility(closes: all.suffix(61).map(\.close), halfLife: nil))
        #expect(abs(live - unbroken) < 1e-12)
        #expect(naive > live * 2)                     // the jump across the gap inflated it
    }

    @Test func tooShortAnUnbrokenRunGivesNothing() {
        let all = candles(minutes: 0..<60, from: 80_000) + candles(minutes: 70..<90, from: 80_000)
        #expect(RiskCalibration.volatility(candles: all, halfLife: nil) == nil)
    }
}

struct TrailingAverageGapTests {
    private func seconds(_ range: ClosedRange<Int>) -> [(time: Date, price: Double)] {
        range.map { (time: Date(timeIntervalSince1970: Double($0)), price: 100.0) }
    }

    @Test func aSampleFromBeforeAGapDoesNotCoverTheWindow() {
        // 20s of data, an 80s gap, then 31s: the last minute holds only 31s of samples.
        #expect(Indicators.trailingAverage(seconds(0...19) + seconds(100...130)).isEmpty)
    }

    @Test func afterAGapTheAverageWaitsForItsOwnCoverage() throws {
        let averages = Indicators.trailingAverage(seconds(0...19) + seconds(100...170))
        // First emitted once the post-gap samples span 55s.
        #expect(try #require(averages.first).time == Date(timeIntervalSince1970: 155))
    }
}

struct ReversalRiskCalibrationInputTests {
    @Test func calibrationGetsTheRawFlipWithoutTrackingError() {
        let calibration = RiskCalibration(flip: [0.1, 0.9], blend: nil, breakout: nil, volatilityHalfLife: nil,
                                          evaluation: .init(), windows: 1000, fittedAt: .distantPast)
        let base = ReversalRisk.Inputs(price: 80_030, strike: 80_000, secondsRemaining: 480, volatility: 1.5,
                                       calibration: calibration)
        var uncertain = base
        uncertain.priceUncertainty = 40
        let raw = SettlementOdds.estimate(price: 80_030, strike: 80_000, secondsRemaining: 480, volatility: 1.5).rawFlip
        let expected = calibration.flipProbability(raw: raw, kalshiFlip: nil)
        #expect(abs(ReversalRisk.assess(base).flipProbability - expected) < 1e-12)
        #expect(abs(ReversalRisk.assess(uncertain).flipProbability - expected) < 1e-12)
        // Without a calibration the uncertainty still widens the flip chance.
        var uncalibrated = uncertain
        uncalibrated.calibration = nil
        var plain = base
        plain.calibration = nil
        #expect(ReversalRisk.assess(uncalibrated).flipProbability > ReversalRisk.assess(plain).flipProbability)
    }

    @Test func scoreRanksOnTheSnapshotsWithAKalshiPrice() {
        var e = RiskCalibration.Evaluation(snapshots: 1000, fixedFlip: 0.10, fittedFlip: 0.09, kalshi: 0.12, blended: 0.11)
        e.kalshiSnapshots = 600
        e.fixedFlipWithKalshi = 0.13
        e.fittedFlipWithKalshi = 0.125
        let flipOnly = RiskCalibration(flip: [0, 1], blend: nil, breakout: nil, volatilityHalfLife: nil,
                                       evaluation: e, windows: 1000, fittedAt: .distantPast)
        let blended = RiskCalibration(flip: [0, 1], blend: [0, 1, 1], breakout: nil, volatilityHalfLife: nil,
                                      evaluation: e, windows: 1000, fittedAt: .distantPast)
        #expect(flipOnly.score == 0.125)               // not the all-snapshot 0.09
        #expect(blended.score == 0.11)
        #expect(blended.score < flipOnly.score)        // like for like, the blend wins
    }
}
