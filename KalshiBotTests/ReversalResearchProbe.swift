// Research test, run on demand (disabled by default): how often a call close to its
// target reversed, which signs gave warning, and whether an exit would have helped. Uses
// the live prediction log and the saved market history (Coinbase minutes, Kalshi odds
// at minutes 3–12). Choices are fitted on the older 70% of windows, scored on the rest.
import Foundation
import SwiftData
import Testing
@testable import KalshiBot

@MainActor
struct ReversalResearchProbe {
    /// One window, from the call at +3 to the close.
    struct Path {
        let time: Date
        let calledUp: Bool
        let won: Bool                 // the called side won
        let strike: Double
        let prices: [Int: Double]     // minute → Coinbase close + offset (index estimate)
        let mids: [Int: Double]       // minute → Kalshi Yes mid
        let vol: [Int: Double]        // minute → volatility per √s
        let settleGap: Double?        // |settlement − strike|, live log only
    }

    static func p(_ up: Bool, _ yes: Double) -> Double { up ? yes : 1 - yes }   // a side's chance from the Yes mid

    static func paths(_ cache: HistoryCache) -> [Path] {
        let byTime = Dictionary(cache.candles.map { (Int($0.time.timeIntervalSince1970), $0) }, uniquingKeysWith: { a, _ in a })
        let indexOf = Dictionary(cache.candles.enumerated().map { (Int($0.element.time.timeIntervalSince1970), $0.offset) },
                                 uniquingKeysWith: { a, _ in a })
        let gaps = cache.markets.values.compactMap { m -> Double? in
            guard let s = m.floorStrike, let c = byTime[Int(m.openTime.timeIntervalSince1970) - 60] else { return nil }
            return s - c.close
        }.sorted()
        let offset = gaps.isEmpty ? 0 : gaps[gaps.count / 2]
        let midsBy = (3...12).map { (m: $0, d: cache.mids(at: TimeInterval($0 * 60))) }
        var out: [Path] = []
        for m in cache.markets.values {
            guard let strike = m.floorStrike, let up = m.settledUp, let mid3 = midsBy[0].d[m.ticker] else { continue }
            let open = Int(m.openTime.timeIntervalSince1970)
            var prices: [Int: Double] = [:], vol: [Int: Double] = [:], mids: [Int: Double] = [:]
            for minute in 1...14 {
                guard let c = byTime[open + (minute - 1) * 60] else { continue }
                prices[minute] = c.close + offset
                if minute >= 3, let idx = indexOf[open + (minute - 1) * 60] {
                    let tail = Array(cache.candles[max(0, idx - 60)...idx])
                    vol[minute] = RiskCalibration.volatility(candles: tail, halfLife: nil)
                }
            }
            for (minute, d) in midsBy { if let v = d[m.ticker] { mids[minute] = v } }
            let calledUp = mid3 >= 0.5
            guard prices[3] != nil, prices[14] != nil, vol[3] != nil else { continue }
            out.append(Path(time: m.openTime, calledUp: calledUp, won: calledUp == up, strike: strike,
                            prices: prices, mids: mids, vol: vol, settleGap: nil))
        }
        return out.sorted { $0.time < $1.time }
    }

    /// The cushion in σ of the movement still to come: + on the called side, − against it.
    static func cushionSigma(_ path: Path, at minute: Int) -> Double? {
        guard let price = path.prices[minute], let v = path.vol[minute] ?? path.vol[3] else { return nil }
        let left = Double(max(900 - minute * 60, 30))
        let signed = (price - path.strike) * (path.calledUp ? 1 : -1)
        return signed / (v * left.squareRoot())   // volatility is in $ per √s
    }

    static func crossings(_ path: Path, through minute: Int) -> Int {
        var side: Bool?, n = 0
        for k in 1...minute { if let p = path.prices[k], p != path.strike { let a = p > path.strike; if let s = side, s != a { n += 1 }; side = a } }
        return n
    }

    @Test(.disabled("Reads the app's saved history and log — run on request"), .timeLimit(.minutes(20))) func probe() throws {
        // ---- Live log ----
        let container = try ModelContainer(for: PredictionRecord.self, TrainingExample.self)
        let records = try container.mainContext.fetch(FetchDescriptor<PredictionRecord>()).filter { $0.actualUp != nil }
        print("PROBE live resolved calls: \(records.count)")
        let cache = HistoryCache.load()
        let all = Self.paths(cache)
        if !records.isEmpty {
            let wrong = records.filter { $0.isCorrect == false }
            print(String(format: "PROBE live: %d right, %d wrong (%.1f%%)", records.count - wrong.count, wrong.count, Double(wrong.count) / Double(records.count) * 100))
            // Distance at the call, in σ of the movement left, using the history's volatility.
            var buckets: [String: (n: Int, wrong: Int, spotSideLost: Int)] = [:]
            var closeFinishes = 0, wrongClose = 0
            for r in records {
                let gapAtCall = r.spotAtPrediction - r.strike
                // The live calls are newer than the saved minutes, so distance is in dollars.
                let key: String = switch abs(gapAtCall) {
                case ..<25: "a under $25"
                case ..<50: "b $25–50"
                case ..<100: "c $50–100"
                case ..<200: "d $100–200"
                default: "e $200 or more"
                }
                var b = buckets[key] ?? (0, 0, 0)
                b.n += 1
                if r.isCorrect == false { b.wrong += 1 }
                if let up = r.actualUp, (gapAtCall >= 0) != up { b.spotSideLost += 1 }
                buckets[key] = b
                if let s = r.settlementValue, abs(s - r.strike) < 25 { closeFinishes += 1; if r.isCorrect == false { wrongClose += 1 } }
            }
            for (k, b) in buckets.sorted(by: { $0.key < $1.key }) {
                print(String(format: "PROBE live cushion %@: %d calls, wrong %d (%.0f%%), side ahead lost %d", String(k.dropFirst(2)), b.n, b.wrong, Double(b.wrong) / Double(max(b.n, 1)) * 100, b.spotSideLost))
            }
            print("PROBE live: settled within $25 of the target: \(closeFinishes) (\(wrongClose) of them wrong)")
            let ahead = records.filter { ($0.spotAtPrediction >= $0.strike) == $0.predictedUp }.count
            print("PROBE live: call on the side the price was on at the call: \(ahead) of \(records.count)")
        }

        // ---- History: when reversals happen ----
        print("PROBE history windows with full paths: \(all.count)  (\(all.first?.time as Any) … \(all.last?.time as Any))")
        let lost = all.filter { !$0.won }
        var lastCross: [Int: Int] = [:]
        for p in lost {
            // Last minute the price was on the called side.
            let last = (3...14).last { m in p.prices[m].map { ($0 > p.strike) == p.calledUp } ?? false }
            lastCross[last ?? 0, default: 0] += 1
        }
        print("PROBE history: \(lost.count) of \(all.count) calls lost (\(String(format: "%.1f", Double(lost.count) / Double(all.count) * 100))%)")
        print("PROBE lost calls — last minute still on the called side: " + (0...14).compactMap { m in lastCross[m].map { "\(m == 0 ? "never" : "+\(m)"):\($0)" } }.joined(separator: " "))
        for m in [3, 6, 9, 12] {
            let atM = all.compactMap { p in Self.cushionSigma(p, at: m).map { (p, $0) } }
            for (lo, hi) in [(-9.0, 0.0), (0.0, 0.5), (0.5, 1.0), (1.0, 2.0), (2.0, 99.0)] {
                let s = atM.filter { $0.1 >= lo && $0.1 < hi }
                guard !s.isEmpty else { continue }
                let lostN = s.filter { !$0.0.won }.count
                print(String(format: "PROBE at +%d cushion %@: %d windows, called side lost %.1f%%", m,
                             (lo < 0 ? "against the call" : "\(lo)–\(hi == 99 ? "∞" : String(hi))σ") as NSString, s.count, Double(lostN) / Double(s.count) * 100))
            }
        }

        // ---- Detection: does anything beat Kalshi's own later price? ----
        let cut = Int(Double(all.count) * 0.7)
        let train = Array(all[..<cut]), test = Array(all[cut...])
        let L = AccuracyResearchProbe.logit
        for m in [6, 9, 12] {
            func usable(_ ps: [Path]) -> [Path] { ps.filter { $0.mids[m] != nil && Self.cushionSigma($0, at: m) != nil && $0.prices[m - 3] != nil } }
            let tr = usable(train), te = usable(test)
            let kalshi: (Path) -> [Double] = { [L(Self.p($0.calledUp, $0.mids[m]!))] }
            let models: [(String, (Path) -> [Double])] = [
                ("Kalshi's price now", kalshi),
                ("+ cushion in σ", { [L(Self.p($0.calledUp, $0.mids[m]!)), Self.cushionSigma($0, at: m)!] }),
                ("+ target crosses so far", { [L(Self.p($0.calledUp, $0.mids[m]!)), Double(Self.crossings($0, through: m))] }),
                ("+ 3-min move against call", { p in
                    let move = (p.prices[m]! - p.prices[m - 3]!) * (p.calledUp ? 1 : -1) / (p.vol[m]! * 180.0.squareRoot())
                    return [L(Self.p(p.calledUp, p.mids[m]!)), move] }),
                ("+ Kalshi's drop since the call", { [L(Self.p($0.calledUp, $0.mids[m]!)), L(Self.p($0.calledUp, $0.mids[m]!)) - L(Self.p($0.calledUp, $0.mids[3]!))] }),
                ("all together", { p in
                    let move = (p.prices[m]! - p.prices[m - 3]!) * (p.calledUp ? 1 : -1) / (p.vol[m]! * 180.0.squareRoot())
                    return [L(Self.p(p.calledUp, p.mids[m]!)), Self.cushionSigma(p, at: m)!, Double(Self.crossings(p, through: m)), move,
                            L(Self.p(p.calledUp, p.mids[m]!)) - L(Self.p(p.calledUp, p.mids[3]!))] }),
            ]
            let y = { (ps: [Path]) in ps.map { $0.won ? 1.0 : 0.0 } }
            let baseP = te.map { Self.p($0.calledUp, $0.mids[m]!) }
            let baseBrier = zip(baseP, y(te)).map { ($0 - $1) * ($0 - $1) }.reduce(0, +) / Double(te.count)
            print(String(format: "PROBE detect at +%d (test n %d): Kalshi raw Brier %.5f", m, te.count, baseBrier))
            for (name, f) in models {
                let w = AccuracyResearchProbe.fit(tr.map(f), y(tr))
                let pr = te.map { AccuracyResearchProbe.predict(w, f($0)) }
                let diffs = zip(zip(baseP, pr), y(te)).map { pair, yy in (pair.0 - yy) * (pair.0 - yy) - (pair.1 - yy) * (pair.1 - yy) }
                let mean = diffs.reduce(0, +) / Double(diffs.count)
                let sd = (diffs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(diffs.count - 1)).squareRoot()
                print(String(format: "PROBE   %-30@ gain vs Kalshi %+.2f ± %.2f milli", name as NSString, mean * 1000, 1.96 * sd / Double(diffs.count).squareRoot() * 1000))
            }
        }

        // ---- Factoring reversal risk into the call ----
        // (a) Skip calls at +3: by Kalshi's confidence, by the cushion in σ, or by the
        //     price-based flip chance — each threshold chosen on train to call a given
        //     share of windows, then scored on test.
        func flipFromPrice(_ p: Path) -> Double? {
            guard let price = p.prices[3], let v = p.vol[3] else { return nil }
            let up = SettlementOdds.estimate(price: price, strike: p.strike, secondsRemaining: 720, volatility: v).probabilityUp
            return p.calledUp ? 1 - up : up
        }
        let filters: [(String, (Path) -> Double?)] = [
            ("Kalshi confidence", { p in p.mids[3].map { Self.p(p.calledUp, $0) } }),
            ("cushion in σ", { Self.cushionSigma($0, at: 3) }),
            ("1 − price-based flip risk", { flipFromPrice($0).map { 1 - $0 } }),
            ("both: min(conf, 1 − flip)", { p in
                guard let c = p.mids[3].map({ Self.p(p.calledUp, $0) }), let f = flipFromPrice(p) else { return nil }
                return min(c, 1 - f) }),
        ]
        for share in [0.65, 0.50, 0.37, 0.25] {
            var line = String(format: "PROBE skip at +3, calling %.0f%%:", share * 100)
            for (name, score) in filters {
                let trainScores = train.compactMap(score).sorted(by: >)
                guard !trainScores.isEmpty else { continue }
                let cutoff = trainScores[min(Int(Double(trainScores.count) * share), trainScores.count - 1)]
                let called = test.filter { (score($0) ?? -.infinity) >= cutoff }
                let acc = Double(called.filter(\.won).count) / Double(max(called.count, 1))
                line += String(format: "  %@ %.1f%% (%.0f%% called)", name as NSString, acc * 100, Double(called.count) / Double(test.count) * 100)
            }
            print(line)
        }
        // (b) Wait for low risk: call the first minute from +3 to +12 when Kalshi's favourite
        //     is at least T (reversal risk ≤ 1 − T), on that minute's favourite; else no call.
        for t in [0.60, 0.65, 0.70, 0.75, 0.80, 0.85, 0.90] {
            var right = 0, called = 0, minuteSum = 0
            for p in test {
                for m in 3...12 {
                    guard let mid = p.mids[m] else { continue }
                    let fav = max(mid, 1 - mid)
                    if fav >= t {
                        called += 1; minuteSum += m
                        let favUp = mid >= 0.5
                        if favUp == (p.won == p.calledUp) { right += 1 }   // the outcome was Up iff won == calledUp
                        break
                    }
                }
            }
            // Fixed +3 with the threshold that calls the same share, for comparison.
            let share = Double(called) / Double(test.count)
            let fixed = test.compactMap { $0.mids[3].map { max($0, 1 - $0) } }.sorted(by: >)
            let cut = fixed[min(Int(Double(fixed.count) * share), fixed.count - 1)]
            let fixedCalled = test.filter { ($0.mids[3].map { max($0, 1 - $0) } ?? 0) >= cut }
            let fixedAcc = Double(fixedCalled.filter(\.won).count) / Double(max(fixedCalled.count, 1))
            print(String(format: "PROBE wait for ≥%.0f%%: %.1f%% right, %.0f%% of windows called, avg minute +%.1f   |  fixed +3 at the same share: %.1f%%",
                         t * 100, Double(right) / Double(max(called, 1)) * 100, share * 100, Double(minuteSum) / Double(max(called, 1)), fixedAcc * 100))
        }

        // Fixed call minutes, every window, for comparison with waiting.
        print("PROBE fixed minute, all windows: " + (3...12).map { m in
            let s = test.compactMap { p in p.mids[m].map { (($0 >= 0.5) == (p.won == p.calledUp)) } }
            return String(format: "+%d %.1f%%", m, Double(s.filter { $0 }.count) / Double(max(s.count, 1)) * 100)
        }.joined(separator: "  "))

        // ---- Response: sell the called side when its price falls below T? ----
        // Buy at +3 at the mid + ½¢ + fee; sell at the first minute (4…12) its mid is below T,
        // at the mid − ½¢ − fee; otherwise hold to settlement ($1 or $0).
        func pnl(_ p: Path, threshold: Double?) -> Double? {
            guard let m3 = p.mids[3] else { return nil }
            let entry = Self.p(p.calledUp, m3)
            let cost = entry + 0.005 + KalshiFees.taker(price: min(max(entry + 0.005, 0.01), 0.99))
            if let t = threshold {
                for m in 4...12 {
                    guard let mid = p.mids[m] else { continue }
                    let side = Self.p(p.calledUp, mid)
                    if side < t {
                        let bid = max(side - 0.005, 0.01)
                        return bid - KalshiFees.taker(price: bid) - cost
                    }
                }
            }
            return (p.won ? 1 : 0) - cost
        }
        func summary(_ ps: [Path], _ t: Double?) -> (Double, Double, Int) {
            let v = ps.compactMap { pnl($0, threshold: t) }
            let mean = v.reduce(0, +) / Double(v.count)
            let sd = (v.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(v.count - 1)).squareRoot()
            return (mean, 1.96 * sd / Double(v.count).squareRoot(), v.count)
        }
        let thresholds: [Double?] = [nil, 0.45, 0.40, 0.35, 0.30, 0.25, 0.20, 0.15, 0.10]
        for t in thresholds {
            let (a, am, _) = summary(train, t), (b, bm, n) = summary(test, t)
            print(String(format: "PROBE exit %@: train %+.2f ± %.2f ¢/contract   test %+.2f ± %.2f ¢ (n %d)",
                         (t.map { "below \(Int($0 * 100))¢" } ?? "hold to settle") as NSString, a * 100, am * 100, b * 100, bm * 100, n))
        }
        // Paired: best train threshold vs holding, on the test windows.
        let best = thresholds.compactMap { $0 }.max { summary(train, $0).0 < summary(train, $1).0 }!
        let paired = test.compactMap { p -> Double? in
            guard let e = pnl(p, threshold: best), let h = pnl(p, threshold: nil) else { return nil }
            return e - h
        }
        let mean = paired.reduce(0, +) / Double(paired.count)
        let sd = (paired.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(paired.count - 1)).squareRoot()
        let exited = test.filter { p in (4...12).contains { m in p.mids[m].map { Self.p(p.calledUp, $0) < best } ?? false } }
        print(String(format: "PROBE best exit on train: below %d¢ — on test vs holding %+.2f ± %.2f ¢/contract; exits %d of %d (of which would have won %d)",
                     Int(best * 100), mean * 100, 1.96 * sd / Double(paired.count).squareRoot() * 100, exited.count, test.count, exited.filter(\.won).count))
    }
}
