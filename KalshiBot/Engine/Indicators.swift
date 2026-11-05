//
//  Indicators.swift
//  KalshiBot
//
//  Pure technical-indicator math. All inputs are ordered oldest → newest.
//

import Foundation

/// One OHLCV bar.
nonisolated struct Candle: Sendable, Equatable {
    let time: Date
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Double
}

nonisolated enum Indicators {

    /// Exponential moving average series (same length as input, seeded with the first value).
    static func emaSeries(_ values: [Double], period: Int) -> [Double] {
        guard let first = values.first, period > 0 else { return [] }
        let k = 2.0 / Double(period + 1)
        var result = [first]
        result.reserveCapacity(values.count)
        for value in values.dropFirst() {
            result.append(value * k + result[result.count - 1] * (1 - k))
        }
        return result
    }

    static func ema(_ values: [Double], period: Int) -> Double? {
        emaSeries(values, period: period).last
    }

    static func sma(_ values: [Double], period: Int) -> Double? {
        guard period > 0, values.count >= period else { return nil }
        return values.suffix(period).reduce(0, +) / Double(period)
    }

    static func standardDeviation(_ values: [Double]) -> Double? {
        guard values.count > 1 else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
        return variance.squareRoot()
    }

    /// Wilder's RSI (0–100).
    static func rsi(_ closes: [Double], period: Int = 14) -> Double? {
        guard closes.count > period else { return nil }
        var gain = 0.0, loss = 0.0
        for i in 1...period {
            let change = closes[i] - closes[i - 1]
            if change > 0 { gain += change } else { loss -= change }
        }
        var avgGain = gain / Double(period)
        var avgLoss = loss / Double(period)
        if closes.count > period + 1 {
            for i in (period + 1)..<closes.count {
                let change = closes[i] - closes[i - 1]
                avgGain = (avgGain * Double(period - 1) + max(change, 0)) / Double(period)
                avgLoss = (avgLoss * Double(period - 1) + max(-change, 0)) / Double(period)
            }
        }
        if avgLoss == 0 { return avgGain == 0 ? 50 : 100 }
        let rs = avgGain / avgLoss
        return 100 - 100 / (1 + rs)
    }

    /// MACD line, signal line and histogram.
    static func macd(_ closes: [Double], fast: Int = 12, slow: Int = 26, signal: Int = 9)
        -> (macd: Double, signal: Double, histogram: Double)? {
        guard closes.count >= slow + signal else { return nil }
        let fastSeries = emaSeries(closes, period: fast)
        let slowSeries = emaSeries(closes, period: slow)
        let macdSeries = zip(fastSeries, slowSeries).map { $0 - $1 }
        let signalSeries = emaSeries(macdSeries, period: signal)
        guard let m = macdSeries.last, let s = signalSeries.last else { return nil }
        return (m, s, m - s)
    }

    /// Bollinger %B: 0 at the lower band, 1 at the upper band.
    static func bollingerPercentB(_ closes: [Double], period: Int = 20, multiplier: Double = 2) -> Double? {
        guard closes.count >= period,
              let mean = sma(closes, period: period),
              let sd = standardDeviation(Array(closes.suffix(period))),
              sd > 0, let last = closes.last else { return nil }
        let lower = mean - multiplier * sd
        let upper = mean + multiplier * sd
        return (last - lower) / (upper - lower)
    }

    /// Wilder's Average True Range.
    static func atr(_ candles: [Candle], period: Int = 14) -> Double? {
        guard candles.count > period else { return nil }
        var trueRanges: [Double] = []
        for i in 1..<candles.count {
            let c = candles[i], prevClose = candles[i - 1].close
            trueRanges.append(max(c.high - c.low, abs(c.high - prevClose), abs(c.low - prevClose)))
        }
        var value = trueRanges.prefix(period).reduce(0, +) / Double(period)
        for tr in trueRanges.dropFirst(period) {
            value = (value * Double(period - 1) + tr) / Double(period)
        }
        return value
    }

    /// Stochastic %K (0–100).
    static func stochasticK(_ candles: [Candle], period: Int = 14) -> Double? {
        guard candles.count >= period, let last = candles.last else { return nil }
        let window = candles.suffix(period)
        guard let high = window.map(\.high).max(), let low = window.map(\.low).min(), high > low else { return nil }
        return (last.close - low) / (high - low) * 100
    }

    /// Volume-weighted average price over the trailing `period` bars (typical price).
    static func vwap(_ candles: [Candle], period: Int) -> Double? {
        let window = candles.suffix(period)
        let volume = window.reduce(0) { $0 + $1.volume }
        guard volume > 0 else { return nil }
        let pv = window.reduce(0) { $0 + ($1.high + $1.low + $1.close) / 3 * $1.volume }
        return pv / volume
    }

    /// Net signed volume over the trailing `period` bars as a fraction of total volume (−1…1).
    /// A rolling, scale-free alternative to an OBV slope.
    static func volumeFlow(_ candles: [Candle], period: Int) -> Double? {
        guard candles.count > period else { return nil }
        var signed = 0.0, total = 0.0
        for i in (candles.count - period)..<candles.count {
            let change = candles[i].close - candles[i - 1].close
            let direction: Double = change > 0 ? 1 : (change < 0 ? -1 : 0)
            signed += direction * candles[i].volume
            total += candles[i].volume
        }
        return total > 0 ? signed / total : nil
    }

    /// Log returns between consecutive values.
    static func logReturns(_ values: [Double]) -> [Double] {
        guard values.count > 1 else { return [] }
        return (1..<values.count).compactMap { i in
            values[i - 1] > 0 && values[i] > 0 ? log(values[i] / values[i - 1]) : nil
        }
    }

    /// Least-squares slope of `values` per sample.
    static func slope(_ values: [Double]) -> Double? {
        let n = Double(values.count)
        guard values.count > 1 else { return nil }
        let meanX = (n - 1) / 2
        let meanY = values.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for (i, y) in values.enumerated() {
            let dx = Double(i) - meanX
            num += dx * (y - meanY)
            den += dx * dx
        }
        return den > 0 ? num / den : nil
    }

    /// Trailing simple average over `window` seconds, evaluated at each sample — the
    /// same construction as Kalshi's settlement (simple average of the 60s of BRTI
    /// before a time). A sample is only emitted once the trailing window is actually
    /// covered: data reaching back at least `minCoverage` seconds and `minSamples` points.
    /// - Parameters:
    ///   - samples: ordered oldest → newest.
    ///   - maxLead: how far before the window's start the last dropped sample may be and
    ///     still count as covering it.
    static func trailingAverage(_ samples: [(time: Date, price: Double)], window: TimeInterval = 60,
                                minCoverage: TimeInterval = 55, minSamples: Int = 20,
                                maxLead: TimeInterval = 5) -> [(time: Date, average: Double)] {
        var result: [(time: Date, average: Double)] = []
        var start = 0
        var sum = 0.0
        for end in samples.indices {
            sum += samples[end].price
            // Drop samples at or before (t − window), keeping the half-open (t − window, t].
            while samples[end].time.timeIntervalSince(samples[start].time) >= window {
                sum -= samples[start].price
                start += 1
            }
            let count = end - start + 1
            // Coverage: the kept samples span far enough back, or the one just dropped sits
            // right at the window's start (so the price there is known). A dropped sample from
            // before a feed gap can be arbitrarily old and says nothing about the window.
            let windowStart = samples[end].time.addingTimeInterval(-window)
            let droppedAtStart = start > 0 && windowStart.timeIntervalSince(samples[start - 1].time) <= maxLead
            let reach = droppedAtStart ? window : samples[end].time.timeIntervalSince(samples[start].time)
            if count >= minSamples && reach >= minCoverage {
                result.append((samples[end].time, sum / Double(count)))
            }
        }
        return result
    }

    /// Groups price samples into 1-minute OHLC candles aligned to `start`
    /// (each stamped with its minute's start time; volume is 0).
    /// - Parameter samples: ordered oldest → newest.
    static func minuteCandles(_ samples: [(time: Date, price: Double)], from start: Date, to end: Date) -> [Candle] {
        var candles: [Candle] = []
        for sample in samples where sample.time >= start && sample.time < end {
            let minute = start.addingTimeInterval(floor(sample.time.timeIntervalSince(start) / 60) * 60)
            if let last = candles.last, last.time == minute {
                candles[candles.count - 1] = Candle(time: minute, open: last.open, high: max(last.high, sample.price),
                                                    low: min(last.low, sample.price), close: sample.price, volume: 0)
            } else {
                candles.append(Candle(time: minute, open: sample.price, high: sample.price,
                                      low: sample.price, close: sample.price, volume: 0))
            }
        }
        return candles
    }

    /// Realized price volatility in dollars per √second, from tick-to-tick changes.
    /// Ticks are irregularly spaced, so variance is normalized by elapsed time;
    /// gaps over 10s (the bot wasn't collecting) are skipped.
    static func realizedVolatility(_ samples: [(time: Date, price: Double)]) -> Double? {
        var squared = 0.0, elapsed = 0.0
        for i in samples.indices.dropFirst() {
            let dt = samples[i].time.timeIntervalSince(samples[i - 1].time)
            guard dt > 0, dt <= 10 else { continue }
            let change = samples[i].price - samples[i - 1].price
            squared += change * change
            elapsed += dt
        }
        return elapsed > 0 ? (squared / elapsed).squareRoot() : nil
    }

    /// Ordinary least-squares line through (x, y) points; nil if there's no spread in x.
    static func linearFit(xs: [Double], ys: [Double]) -> (slope: Double, intercept: Double)? {
        let n = Double(min(xs.count, ys.count))
        guard n >= 2 else { return nil }
        let meanX = xs.reduce(0, +) / n, meanY = ys.reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0
        for (x, y) in zip(xs, ys) {
            sxx += (x - meanX) * (x - meanX)
            sxy += (x - meanX) * (y - meanY)
        }
        guard sxx > 0 else { return nil }
        let slope = sxy / sxx
        return (slope, meanY - slope * meanX)
    }

    /// Standard normal CDF.
    static func normalCDF(_ x: Double) -> Double {
        0.5 * erfc(-x / 2.0.squareRoot())
    }
}
