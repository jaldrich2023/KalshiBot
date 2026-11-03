//
//  WindowProjection.swift
//  KalshiBot
//
//  Where the window is likely to settle, and the trend so far.
//
//  The forecast is the current price, not the trend extended to the close. A 30-day
//  backtest (2,848 windows) found extending the fitted trend missed the settlement by
//  $278 on average at +2 min vs. $82 for "price now", and was further off in 68–82% of
//  windows at every minute: over 15 minutes BTC is close to a random walk, so a recent
//  drift says little about the rest of the window. The trend is still fitted and shown,
//  over the stretch it describes.
//

import Foundation

nonisolated struct WindowProjection: Sendable, Equatable {
    /// Least-squares trend through the window's ticks so far: price = intercept + slope · (t − open).
    let slopePerSecond: Double
    let intercept: Double
    /// Seconds after the open that the trend was fitted over.
    var fitStart: TimeInterval = 0
    var fitEnd: TimeInterval = 0
    /// Forecast of the settlement (the final-minute average): the current price.
    let forecastSettlement: Double
    /// Realized volatility of price, in dollars per √second.
    let volatilityPerRootSecond: Double

    /// The trend line's value `seconds` after the open.
    func trendValue(at seconds: TimeInterval) -> Double {
        intercept + slopePerSecond * seconds
    }

    /// 1σ uncertainty of the settlement value `secondsRemaining` before the close. The
    /// settlement averages the final minute, which carries only ~⅓ of a minute's
    /// variance; everything before that minute carries full variance.
    func settlementSigma(secondsRemaining: TimeInterval) -> Double {
        let remaining = max(secondsRemaining, 0)
        let effective = max(remaining - 60, 0) + min(remaining, 60) / 3
        return volatilityPerRootSecond * effective.squareRoot()
    }

    /// Probability that the window settles at or above `strike`, starting from the current price.
    func probabilityUp(strike: Double, secondsRemaining: TimeInterval) -> Double {
        let sigma = settlementSigma(secondsRemaining: secondsRemaining)
        guard sigma > 0 else { return forecastSettlement >= strike ? 1 : 0 }
        return Indicators.normalCDF((forecastSettlement - strike) / sigma)
    }

    /// Fits the trend to price action since the open and takes the latest price as the forecast.
    /// - Parameters:
    ///   - samples: price ticks, oldest → newest (only those inside the window are used).
    ///   - volatility: dollars per √second; defaults to the realized volatility of `samples`.
    ///   - minimumSpan: seconds of in-window data required before projecting.
    static func fit(_ samples: [(time: Date, price: Double)], open: Date, close: Date, volatility: Double? = nil,
                    minimumSpan: TimeInterval = 60, minimumSamples: Int = 30) -> WindowProjection? {
        let window = samples.filter { $0.time >= open && $0.time <= close }
        guard window.count >= minimumSamples, let first = window.first, let last = window.last,
              last.time.timeIntervalSince(first.time) >= minimumSpan,
              let line = Indicators.linearFit(xs: window.map { $0.time.timeIntervalSince(open) }, ys: window.map(\.price))
        else { return nil }

        return WindowProjection(slopePerSecond: line.slope, intercept: line.intercept,
                                fitStart: first.time.timeIntervalSince(open), fitEnd: last.time.timeIntervalSince(open),
                                forecastSettlement: last.price,
                                volatilityPerRootSecond: volatility ?? Indicators.realizedVolatility(window) ?? 0)
    }
}
