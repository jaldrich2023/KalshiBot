// Research test, run on demand (disabled by default): new ways to beat Kalshi's price at
// the +3 call, on the saved market history. Each idea is fitted on the older 70% of
// windows and scored on the newest 30%, against Kalshi's mid at +3.
import Foundation
import Testing
@testable import KalshiBot

struct AccuracyResearchProbe {
    struct Row {
        let time: Date
        let up: Bool
        let mid: Double            // Kalshi mid at +3
        let mid4: Double?          // at +4 (later calls only)
        let hourET: Int
        let weekend: Bool
        let priceOdds: Double?     // P(up) from Coinbase spot, strike, time left, volatility
        let volZ: Double?          // log(volatility / median)
        let residual: Double?      // Kalshi's recent miss: mean(outcome − mid) over windows k−9…k−2
        let roundGap: Double       // strike's distance to the nearest $250, in $
    }

    static func logit(_ p: Double) -> Double { let q = min(max(p, 0.005), 0.995); return log(q / (1 - q)) }
    static func sigmoid(_ x: Double) -> Double { 1 / (1 + exp(-x)) }

    /// L2-regularized logistic regression by Newton's method (intercept included).
    static func fit(_ x: [[Double]], _ y: [Double], l2: Double = 1e-3) -> [Double] {
        let d = (x.first?.count ?? 0) + 1
        var w = [Double](repeating: 0, count: d)
        if d > 1 { w[1] = 1 }  // start at "Kalshi as is" when feature 0 is logit(mid)
        for _ in 0..<50 {
            var g = [Double](repeating: 0, count: d)
            var h = [[Double]](repeating: [Double](repeating: 0, count: d), count: d)
            for (xi, yi) in zip(x, y) {
                let v = [1] + xi
                let p = sigmoid(zip(w, v).map(*).reduce(0, +))
                for a in 0..<d {
                    g[a] += (p - yi) * v[a]
                    for b in 0..<d { h[a][b] += p * (1 - p) * v[a] * v[b] }
                }
            }
            for a in 1..<d { g[a] += l2 * w[a]; h[a][a] += l2 }
            guard let step = solve(h, g) else { break }
            for a in 0..<d { w[a] -= step[a] }
            if step.map(abs).max() ?? 0 < 1e-9 { break }
        }
        return w
    }

    static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        var m = a, v = b
        let n = v.count
        for c in 0..<n {
            guard let p = (c..<n).max(by: { abs(m[$0][c]) < abs(m[$1][c]) }), abs(m[p][c]) > 1e-12 else { return nil }
            m.swapAt(c, p); v.swapAt(c, p)
            for r in 0..<n where r != c {
                let f = m[r][c] / m[c][c]
                for k in c..<n { m[r][k] -= f * m[c][k] }
                v[r] -= f * v[c]
            }
        }
        return (0..<n).map { v[$0] / m[$0][$0] }
    }

    static func predict(_ w: [Double], _ x: [Double]) -> Double { sigmoid(zip(w, [1] + x).map(*).reduce(0, +)) }

    struct Score { let n: Int; let acc: Double; let brier: Double; let dBrier: Double; let dMargin: Double; let flips: Int; let flipsRight: Int }

    /// Paired comparison with Kalshi's mid on the same windows.
    static func score(_ p: [Double], _ rows: [Row]) -> Score {
        let n = Double(rows.count)
        var acc = 0.0, brier = 0.0, diffs: [Double] = [], flips = 0, flipsRight = 0
        for (pi, r) in zip(p, rows) {
            let y = r.up ? 1.0 : 0.0
            acc += ((pi >= 0.5) == r.up) ? 1 : 0
            let b = (pi - y) * (pi - y), k = (r.mid - y) * (r.mid - y)
            brier += b
            diffs.append(k - b)  // positive = better than Kalshi
            if (pi >= 0.5) != (r.mid >= 0.5) { flips += 1; if (pi >= 0.5) == r.up { flipsRight += 1 } }
        }
        let mean = diffs.reduce(0, +) / n
        let sd = (diffs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / (n - 1)).squareRoot()
        return Score(n: rows.count, acc: acc / n, brier: brier / n, dBrier: mean, dMargin: 1.96 * sd / n.squareRoot(), flips: flips, flipsRight: flipsRight)
    }

    static func rows(from cache: HistoryCache) -> [Row] {
        let et = TimeZone(identifier: "America/New_York")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = et
        let mids3 = cache.mids(at: 180), mids4 = cache.mids(at: 240)
        let candles = cache.candles
        let times = candles.map(\.time.timeIntervalSince1970)
        let markets = cache.markets.values.filter { $0.floorStrike != nil && $0.settledUp != nil && mids3[$0.ticker] != nil }
            .sorted { $0.openTime < $1.openTime }

        // Coinbase-to-index offset: median(strike − last Coinbase close before the open).
        func lastIndex(before t: Date) -> Int? {
            var lo = 0, hi = times.count - 1, best: Int?
            let target = t.timeIntervalSince1970
            while lo <= hi { let m = (lo + hi) / 2; if times[m] + 60 <= target { best = m; lo = m + 1 } else { hi = m - 1 } }
            return best
        }
        let gaps = markets.compactMap { m -> Double? in lastIndex(before: m.openTime).map { m.floorStrike! - candles[$0].close } }.sorted()
        let offset = gaps.isEmpty ? 0 : gaps[gaps.count / 2]

        var vols: [Double?] = []
        var out: [Row] = []
        var recent: [(up: Bool, mid: Double)] = []
        for m in markets {
            let call = m.openTime.addingTimeInterval(180)
            let mid = mids3[m.ticker]!
            var priceOdds: Double?, vol: Double?
            if let i = lastIndex(before: call) {
                let window = Array(candles[max(0, i - 60)...i])
                vol = RiskCalibration.volatility(candles: window, halfLife: nil)
                if let vol, vol > 0 {
                    priceOdds = SettlementOdds.estimate(price: candles[i].close + offset, strike: m.floorStrike!,
                                                        secondsRemaining: 720, volatility: vol).probabilityUp
                }
            }
            vols.append(vol)
            // Kalshi's recent misses: windows that closed at least 15 minutes before this open.
            let past = recent.dropLast(1).suffix(8)
            let residual = past.count == 8 ? past.map { ($0.up ? 1 : 0) - $0.mid }.reduce(0, +) / 8 : nil
            let strike = m.floorStrike!
            let gap = abs(strike - (strike / 250).rounded() * 250)
            out.append(Row(time: m.openTime, up: m.settledUp!, mid: mid, mid4: mids4[m.ticker],
                           hourET: cal.component(.hour, from: m.openTime),
                           weekend: [1, 7].contains(cal.component(.weekday, from: m.openTime)),
                           priceOdds: priceOdds, volZ: nil, residual: residual, roundGap: gap))
            recent.append((m.settledUp!, mid))
        }
        let sortedVols = vols.compactMap { $0 }.sorted()
        let medianVol = sortedVols.isEmpty ? 1 : sortedVols[sortedVols.count / 2]
        return zip(out, vols).map { r, v in
            Row(time: r.time, up: r.up, mid: r.mid, mid4: r.mid4, hourET: r.hourET, weekend: r.weekend, priceOdds: r.priceOdds,
                volZ: v.map { log($0 / medianVol) }, residual: r.residual, roundGap: r.roundGap)
        }
    }

    @Test(.disabled("Reads the app's saved history — run on request"), .timeLimit(.minutes(20))) func probe() throws {
        let cache = HistoryCache.load()
        let all = Self.rows(from: cache).filter { $0.priceOdds != nil && $0.volZ != nil && $0.residual != nil }
        print("PROBE rows=\(all.count) markets=\(cache.markets.count) candles=\(cache.candles.count) first=\(all.first?.time as Any) last=\(all.last?.time as Any)")
        guard all.count > 1000 else { return }
        let cut = Int(Double(all.count) * 0.7)
        let train = Array(all[..<cut]), test = Array(all[cut...])
        let L = Self.logit

        func block(_ h: Int) -> Int { h / 4 }   // six 4-hour blocks, ET
        let models: [(String, (Row) -> [Double])] = [
            ("recalibrate Kalshi", { [L($0.mid)] }),
            ("+ hour block (ET)", { r in [L(r.mid)] + (1..<6).map { Double(block(r.hourET) == $0 ? 1 : 0) } + (1..<6).map { Double(block(r.hourET) == $0 ? 1 : 0) * L(r.mid) } }),
            ("+ weekend", { [L($0.mid), $0.weekend ? 1 : 0, ($0.weekend ? 1 : 0) * L($0.mid)] }),
            ("+ volatility regime", { [L($0.mid), $0.volZ!, $0.volZ! * L($0.mid)] }),
            ("+ price-based odds", { [L($0.mid), L($0.priceOdds!)] }),
            ("+ Kalshi's recent misses", { [L($0.mid), $0.residual!] }),
            ("+ strike near round $250", { [L($0.mid), $0.roundGap / 125, ($0.roundGap / 125) * L($0.mid)] }),
            ("all of the above", { r in [L(r.mid), r.weekend ? 1 : 0, r.volZ!, r.volZ! * L(r.mid), L(r.priceOdds!), r.residual!]
                + (1..<6).map { Double(block(r.hourET) == $0 ? 1 : 0) } }),
        ]

        let base = Self.score(test.map(\.mid), test)
        print(String(format: "PROBE test n=%d  Kalshi: acc %.4f  Brier %.5f", base.n, base.acc, base.brier))
        for (name, feats) in models {
            let w = Self.fit(train.map(feats), train.map { $0.up ? 1 : 0 })
            let s = Self.score(test.map { Self.predict(w, feats($0)) }, test)
            print(String(format: "PROBE %-26@ acc %.4f (%+.2f pts)  Brier %.5f  gain %+.2f ± %.2f milli  flips %d (right %d)",
                         name as NSString, s.acc, (s.acc - base.acc) * 100, s.brier, s.dBrier * 1000, s.dMargin * 1000, s.flips, s.flipsRight))
        }

        // Where is Kalshi miscalibrated, consistently in both halves? (outcome − mid by hour block)
        for b in 0..<6 {
            func res(_ rows: [Row]) -> (Double, Int) {
                let r = rows.filter { block($0.hourET) == b }
                return (r.map { ($0.up ? 1 : 0) - $0.mid }.reduce(0, +) / Double(max(r.count, 1)), r.count)
            }
            let (a, na) = res(train), (c, nc) = res(test)
            print(String(format: "PROBE block %02d-%02d ET  train mean(outcome−mid) %+.4f (n %d)  test %+.4f (n %d)", b * 4, b * 4 + 4, a, na, c, nc))
        }

        // Selective accuracy: hit rate of calls at each threshold, train vs test.
        for t in [0.5, 0.55, 0.6, 0.65, 0.7, 0.75, 0.8] {
            func sel(_ rows: [Row]) -> (Double, Double) {
                let s = rows.filter { max($0.mid, 1 - $0.mid) >= t }
                let right = s.filter { ($0.mid >= 0.5) == $0.up }.count
                return (Double(right) / Double(max(s.count, 1)), Double(s.count) / Double(rows.count))
            }
            let (ta, tc) = sel(train), (sa, sc) = sel(test)
            print(String(format: "PROBE calls >= %.2f  train acc %.4f (%.0f%% called)  test acc %.4f (%.0f%% called)", t, ta, tc * 100, sa, sc * 100))
        }
    }
}
