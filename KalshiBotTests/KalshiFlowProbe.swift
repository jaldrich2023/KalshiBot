// Research test, run on demand (disabled by default): does Kalshi's own trading activity
// predict outcomes beyond its price? It downloads several days of Kalshi trades, so it's slow.
import Foundation
import Testing
@testable import KalshiBot

struct KalshiFlowProbe {
    struct Trade { let time: Date; let yesTaker: Bool; let count: Double; let yesPrice: Double }

    static func trades(ticker: String, until: Date) async -> [Trade] {
        var out: [Trade] = []
        var cursor: String?
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for _ in 0..<20 {
            var c = URLComponents(string: "https://api.elections.kalshi.com/trade-api/v2/markets/trades")!
            c.queryItems = [URLQueryItem(name: "ticker", value: ticker), URLQueryItem(name: "limit", value: "1000"),
                            URLQueryItem(name: "max_ts", value: String(Int(until.timeIntervalSince1970)))]
                + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
            var json: [String: Any]?
            for attempt in 0..<5 {
                if let (d, r) = try? await URLSession.shared.data(from: c.url!), (r as? HTTPURLResponse)?.statusCode == 200 {
                    json = try? JSONSerialization.jsonObject(with: d) as? [String: Any]; break
                }
                try? await Task.sleep(for: .milliseconds(500 * (attempt + 1)))
            }
            guard let json, let list = json["trades"] as? [[String: Any]] else { break }
            for t in list {
                guard let ts = t["created_time"] as? String, let time = iso.date(from: ts),
                      let side = t["taker_side"] as? String,
                      let count = Double(t["count_fp"] as? String ?? "") ?? (t["count"] as? Double),
                      let yes = Double(t["yes_price_dollars"] as? String ?? "") else { continue }
                out.append(Trade(time: time, yesTaker: side == "yes", count: count, yesPrice: yes))
            }
            cursor = json["cursor"] as? String
            if cursor?.isEmpty ?? true || list.count < 1000 { break }
        }
        return out
    }

    @Test(.disabled("Long network test — run on request"), .timeLimit(.minutes(30))) func probe() async throws {
        var out = ""
        func say(_ s: String) { out += s + "\n"; print(s) }
        let since = Date.now.addingTimeInterval(-20 * 86400)
        let kalshi = KalshiClient()
        let markets = try await kalshi.settledMarkets(closedAfter: since)
            .filter { $0.settledUp != nil && $0.openTime >= since }.sorted { $0.openTime < $1.openTime }
        let (mids, _, _, _) = await kalshi.yesMids(markets, at: [120, 180])
        say("markets \(markets.count), mids@3 \(mids[180]?.count ?? 0), mids@2 \(mids[120]?.count ?? 0)")

        struct Row { let pK: Double; let y: Bool; var x: [String: Double] }
        var rows: [Row] = []
        // Fetch trades in parallel groups of 6.
        var index = 0
        while index < markets.count {
            let group = Array(markets[index..<min(index + 6, markets.count)])
            index += 6
            let fetched = await withTaskGroup(of: (String, [Trade]).self) { g in
                for m in group { g.addTask { (m.ticker, await Self.trades(ticker: m.ticker, until: m.openTime.addingTimeInterval(180))) } }
                var r: [String: [Trade]] = [:]
                for await (t, list) in g { r[t] = list }
                return r
            }
            for m in group {
                guard let p3 = mids[180]?[m.ticker], p3 > 0.01, p3 < 0.99, let up = m.settledUp else { continue }
                let call = m.openTime.addingTimeInterval(180)
                let ts = (fetched[m.ticker] ?? []).filter { $0.time >= m.openTime && $0.time < call }
                var x: [String: Double] = [:]
                let total = ts.reduce(0) { $0 + $1.count }
                if total > 0 {
                    x["flowSinceOpen"] = ts.reduce(0) { $0 + ($1.yesTaker ? $1.count : -$1.count) } / total
                    x["volume"] = log(total)
                }
                let last = ts.filter { $0.time >= call.addingTimeInterval(-60) }
                let lastTotal = last.reduce(0) { $0 + $1.count }
                if lastTotal > 0 { x["flowLastMinute"] = last.reduce(0) { $0 + ($1.yesTaker ? $1.count : -$1.count) } / lastTotal }
                if let lt = ts.max(by: { $0.time < $1.time }) { x["lastTradeVsMid"] = (lt.yesPrice - p3) * 100 }
                if let p2 = mids[120]?[m.ticker], p2 > 0.01, p2 < 0.99 {
                    x["kalshiMove1m"] = log(p3 / (1 - p3)) - log(p2 / (1 - p2))
                }
                rows.append(Row(pK: p3, y: up, x: x))
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        say("rows \(rows.count), with trades \(rows.filter { $0.x["flowSinceOpen"] != nil }.count)")

        func logit(_ p: Double) -> Double { log(p / (1 - p)) }
        func sigm(_ z: Double) -> Double { 1 / (1 + exp(-z)) }
        func fit(_ X: [[Double]], _ y: [Double]) -> [Double] {
            let k = X[0].count; var w = [Double](repeating: 0, count: k); w[1] = 1
            for _ in 0..<30 {
                var g = [Double](repeating: 0, count: k), H = [[Double]](repeating: [Double](repeating: 0, count: k), count: k)
                for (xi, yi) in zip(X, y) {
                    let p = sigm(zip(w, xi).reduce(0) { $0 + $1.0 * $1.1 })
                    for a in 0..<k { g[a] += (p - yi) * xi[a]; for b in 0..<k { H[a][b] += p * (1 - p) * xi[a] * xi[b] } }
                }
                for a in 0..<k { H[a][a] += 1e-6 }
                var A = H, bv = g
                for i in 0..<k { let piv = A[i][i]; for j in (i + 1)..<k { let f = A[j][i] / piv; for c in i..<k { A[j][c] -= f * A[i][c] }; bv[j] -= f * bv[i] } }
                var d = [Double](repeating: 0, count: k)
                for i in stride(from: k - 1, through: 0, by: -1) { var s = bv[i]; for j in (i + 1)..<k { s -= A[i][j] * d[j] }; d[i] = s / A[i][i] }
                for a in 0..<k { w[a] -= d[a] }
            }
            return w
        }
        for name in ["flowSinceOpen", "flowLastMinute", "kalshiMove1m", "lastTradeVsMid", "volume"] {
            let usable = rows.compactMap { r in r.x[name].map { (r, $0) } }
            guard usable.count >= 200 else { say("\(name): too few rows \(usable.count)"); continue }
            let xs = usable.map(\.1); let mean = xs.reduce(0, +) / Double(xs.count)
            let sd = (xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(xs.count)).squareRoot()
            let z = { (v: Double) in sd > 0 ? (v - mean) / sd : 0 }
            // Volume is non-directional: test it as an interaction with Kalshi's log-odds.
            let feature = { (r: Row, v: Double) in name == "volume" ? z(v) * logit(r.pK) : z(v) }
            let half = usable.count / 2
            let train = usable[..<half], test = usable[half...]
            let wb = fit(train.map { [1, logit($0.0.pK)] }, train.map { $0.0.y ? 1 : 0 })
            let wf = fit(train.map { [1, logit($0.0.pK), feature($0.0, $0.1)] }, train.map { $0.0.y ? 1 : 0 })
            var diffs: [Double] = []
            for (r, v) in test {
                let y = r.y ? 1.0 : 0
                let pb = sigm(wb[0] + wb[1] * logit(r.pK)), pf = sigm(wf[0] + wf[1] * logit(r.pK) + wf[2] * feature(r, v))
                diffs.append(((pb - y) * (pb - y) - (pf - y) * (pf - y)) * 100)
            }
            let md = diffs.reduce(0, +) / Double(diffs.count)
            let se = (diffs.reduce(0) { $0 + ($1 - md) * ($1 - md) } / Double(diffs.count - 1) / Double(diffs.count)).squareRoot()
            say(String(format: "%@ n=%d | held-out Brier gain %+.3f ± %.3f pts | weight %+.3f", name, usable.count, md, 1.96 * se, wf[2]))
        }
        try out.write(toFile: NSTemporaryDirectory() + "kalshi_flow_probe.txt", atomically: true, encoding: .utf8)
    }
}
