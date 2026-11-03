//
//  ModelTrainer.swift
//  KalshiBot
//
//  Fits the prediction model on every settled window seen so far, and measures it
//  honestly on windows it wasn't trained on.
//

import Foundation

/// One settled window: the indicator values at its open and what actually happened.
nonisolated struct TrainingSample: Sendable {
    let features: [FeatureKey: Double]
    let wentUp: Bool
    let time: Date
}

/// One promotion trial: does adding this signal (or keeping it, if promoted) improve
/// predictions on held-out windows by more than chance?
nonisolated struct TrialResult: Codable, Sendable, Equatable {
    /// Mean per-window log-loss improvement from having the signal (positive = helps).
    var gain: Double
    /// 95% margin of error on `gain`.
    var margin: Double
    /// Share of training windows that have this signal at all.
    var coverage: Double
    var windows: Int
    /// Trialled only on the windows that have the signal (e.g. tick momentum, which
    /// exists only for windows the bot watched live). Nil on results saved before 2.2.0.
    var liveOnly: Bool?
    /// Windows that have the signal, for a live-only trial.
    var liveWindows: Int?
    /// Whether this result was judged on fresh windows — ones that settled after the
    /// signal's previous counted result — so it counts toward promotion or demotion.
    /// Results that reuse already-judged windows are shown but don't count.
    var counted: Bool?
    /// Windows in the trial's pool when this counted result was made; the next counted
    /// result needs `freshWindowsPerTrial` more.
    var mark: Int?

    var hasEnoughData: Bool {
        if liveOnly == true { return (liveWindows ?? 0) >= ModelTrainer.minimumLiveTrialWindows }
        return coverage >= ModelTrainer.minimumTrialCoverage
    }
    /// Helps by more than its margin of error (which is widened for testing several signals).
    var isSignificantGain: Bool { hasEnoughData && gain > margin }
    /// Counts toward a promotion or demotion streak.
    var counts: Bool { hasEnoughData && counted == true }
}

/// Walk-forward check: fit on older windows, score on the newest ones.
nonisolated struct ModelEvaluation: Codable, Sendable, Equatable {
    var holdoutCount: Int
    var accuracy: Double
    var brierScore: Double
    /// The untrained starting weights scored on the same holdout windows.
    var priorAccuracy: Double
    var priorBrierScore: Double
    /// Prior-pull strength chosen by tuning.
    var regularization: Double
    /// Walk-forward blocks scored, and how many the learned weights won (nil before 2.16).
    var folds: Int?
    var foldsWon: Int?
    /// Average log-loss on the scored windows (lower is better), learned vs. starting
    /// weights — the "overall" test for switching (nil before 2.21).
    var logLoss: Double?
    var priorLogLoss: Double?
    /// Per-window log-loss improvement of the learned weights over the starting weights
    /// across the scored windows, and its 95% margin of error (nil before 2.22).
    var gain: Double?
    var gainMargin: Double?

    /// The improvement is bigger than chance.
    var isSignificantGain: Bool { (gain ?? 0) > (gainMargin ?? .infinity) }
    /// The learned weights do significantly worse than the starting weights.
    var isSignificantLoss: Bool { (gain ?? 0) < -(gainMargin ?? .infinity) }
}

nonisolated enum ModelTrainer {

    /// Minimum settled windows before a holdout split is meaningful.
    static let minimumForEvaluation = 60

    /// Prior-pull strengths tried during tuning, weakest to strongest (in units of windows).
    static let regularizationCandidates: [Double] = [10, 30, 100, 300, 1000]
    /// Used before there's enough history to tune.
    static let defaultRegularization: Double = 300

    /// Share of the newest windows scored walk-forward, and the blocks it's split into.
    static let walkForwardShare = 0.4
    static let walkForwardFolds = 4
    /// Below this many windows, a single 80/20 split is used instead of blocks.
    static let minimumForWalkForward = 400
    /// New settled windows a signal's trial needs before another result counts.
    static let freshWindowsPerTrial = 200

    /// Walk-forward training:
    /// 1. Tune the prior-pull strength on the windows before the newest 40%.
    /// 2. Split the newest 40% into four blocks in time order. For each, fit on every
    ///    window before it and score the learned and starting weights on the block.
    /// 3. Deploy learned weights (refitted on everything) only if they won at least
    ///    three of the four blocks and overall; otherwise keep the starting weights.
    /// 4. Trial each context signal (see `trial`): a result counts toward promotion only
    ///    when judged on windows that settled since its last counted result, and its
    ///    significance bar is raised for testing several signals at once.
    ///
    /// A market-anchored model only learns from windows where Kalshi's odds are known;
    /// a window without them would look like "the market said 50/50" and skew the fit.
    /// - Parameter usingLearned: whether the model in use already predicts with learned
    ///   weights under this rule. Switching on takes a significant gain; once on, it stays
    ///   on unless the learned weights fall clearly behind (see `decide`).
    static func train(_ samples: [TrainingSample], excluding excluded: Set<FeatureKey>,
                      promoted: Set<FeatureKey> = [], lastTrialMarks: [String: Int] = [:],
                      usingLearned: Bool = false, now: Date = .now) -> PredictionModel {
        let starting = PredictionModel.starting(excluding: excluded, promoted: promoted)
        let usable = starting.marketAnchored ? samples.filter { $0.features[.kalshiImplied] != nil } : samples
        let sorted = usable.sorted { $0.time < $1.time }
        guard sorted.count >= minimumForEvaluation else {
            // Too little history to prove anything yet — keep the starting weights.
            var model = starting
            model.trainingCount = sorted.count
            model.trainedAt = now
            return model
        }

        // Blocks: four in the newest 40%, or one newest-20% block for a short history.
        let useBlocks = sorted.count >= minimumForWalkForward
        let firstTest = Int(Double(sorted.count) * (useBlocks ? 1 - walkForwardShare : 0.8))
        let folds = useBlocks ? walkForwardFolds : 1
        let lambda = tuneRegularization(Array(sorted[..<firstTest]), excluding: excluded, promoted: promoted)

        var won = 0
        var learnedScores: [TrainingSample] = []
        var diffs: [Double] = []
        var fittedLoss = 0.0, priorLoss = 0.0, fittedBrier = 0.0, priorBrier = 0.0, fittedRight = 0, priorRight = 0
        for fold in 0..<folds {
            let lower = firstTest + (sorted.count - firstTest) * fold / folds
            let upper = firstTest + (sorted.count - firstTest) * (fold + 1) / folds
            guard upper > lower else { continue }
            let before = Array(sorted[..<lower]), block = Array(sorted[lower..<upper])
            // Recency weighting is anchored at the end of the fitting slice, so each block
            // is scored exactly as if it were the future.
            let trained = fit(before, excluding: excluded, promoted: promoted, now: before.last?.time ?? now, regularization: lambda)
            let fitted = score(trained, on: block, excluding: excluded)
            let prior = score(starting, on: block, excluding: excluded)
            diffs += block.map { logLoss(starting, $0, excluding: excluded) - logLoss(trained, $0, excluding: excluded) }
            if fitted.logLoss < prior.logLoss { won += 1 }
            let n = Double(block.count)
            fittedLoss += fitted.logLoss * n; priorLoss += prior.logLoss * n
            fittedBrier += fitted.brier * n; priorBrier += prior.brier * n
            fittedRight += Int((fitted.accuracy * n).rounded()); priorRight += Int((prior.accuracy * n).rounded())
            learnedScores += block
        }
        let scored = Double(max(learnedScores.count, 1))
        let n = Double(diffs.count)
        let meanGain = n > 0 ? diffs.reduce(0, +) / n : 0
        let gainVariance = n > 1 ? diffs.reduce(0) { $0 + ($1 - meanGain) * ($1 - meanGain) } / (n - 1) : 0
        let gainMargin = n > 1 ? 1.96 * (gainVariance / n).squareRoot() : .infinity
        let learnedHelps = decide(usingLearned: usingLearned, won: won, folds: folds, gain: meanGain, margin: gainMargin)

        // Recency is measured from the newest window, not the wall clock, so history
        // doesn't fade away just because the app wasn't running for a while.
        var model = learnedHelps
            ? fit(sorted, excluding: excluded, promoted: promoted, now: sorted.last?.time ?? now, regularization: lambda)
            : starting
        model.trainingCount = sorted.count
        model.trainedAt = now
        model.usesLearnedWeights = learnedHelps
        model.evaluation = ModelEvaluation(
            holdoutCount: learnedScores.count,
            accuracy: Double(fittedRight) / scored, brierScore: fittedBrier / scored,
            priorAccuracy: Double(priorRight) / scored, priorBrierScore: priorBrier / scored,
            regularization: lambda, folds: folds, foldsWon: won,
            logLoss: fittedLoss / scored, priorLogLoss: priorLoss / scored,
            gain: meanGain, gainMargin: gainMargin
        )
        let candidates = FeatureKey.promotionCandidates.filter { !excluded.contains($0) }
        for key in candidates {
            model.trials[key.rawValue] = trial(key, samples: sorted, excluding: excluded, promoted: promoted, lambda: lambda,
                                               lastMark: lastTrialMarks[key.rawValue], testedSignals: candidates.count)
        }
        return model
    }

    /// Switching on needs most blocks *and* an overall gain bigger than its margin of
    /// error, so chance can't switch the model over. Once on, the learned weights stay
    /// unless they fall clearly behind — winning fewer than half the blocks, or doing
    /// significantly worse overall — so a small dip doesn't flip the model back and forth.
    static func decide(usingLearned: Bool, won: Int, folds: Int, gain: Double, margin: Double) -> Bool {
        if usingLearned {
            let losingBlocks = Double(won) < Double(folds) / 2
            let significantlyWorse = gain < -margin
            return !(losingBlocks || significantlyWorse)
        }
        return won >= max(folds - 1, 1) && gain > margin
    }

    /// Fraction of windows a trial signal must be present in to be judged fairly.
    static let minimumTrialCoverage = 0.5
    /// A signal present in fewer windows (live-only ones like tick momentum) is trialled
    /// on just the windows that have it, once there are this many (~5 days live).
    static let minimumLiveTrialWindows = 500

    /// z for a two-sided 95% test spread over `count` tests (Bonferroni): 1.96 for one,
    /// ≈2.77 for the nine context signals. Testing nine at 95% each would let one look significant by
    /// chance more than a third of the time.
    static func zScore(forTests count: Int) -> Double {
        let tail = 0.025 / Double(max(count, 1))
        var lo = 0.0, hi = 10.0
        for _ in 0..<60 {
            let mid = (lo + hi) / 2
            if 1 - Indicators.normalCDF(mid) > tail { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    /// Tests whether `key` earns its place: fits the model with and without the signal on
    /// older windows and compares them window by window on newer ones. A positive `gain`
    /// means the signal helps; it's significant only if larger than its margin, which is
    /// widened for the number of signals tested.
    ///
    /// The judged windows are those that settled since the signal's last counted result
    /// (`lastMark`), once there are `freshWindowsPerTrial` of them, so each counted result
    /// is new evidence. Until then the newest 20% is judged for display, and the result
    /// doesn't count. Sparse signals (live-only ones like tick momentum) are judged only on
    /// the windows that have them.
    static func trial(_ key: FeatureKey, samples sorted: [TrainingSample], excluding excluded: Set<FeatureKey>,
                      promoted: Set<FeatureKey>, lambda: Double, lastMark: Int?, testedSignals: Int) -> TrialResult {
        let coverage = Double(sorted.count { $0.features[key] != nil }) / Double(max(sorted.count, 1))
        let withKey = promoted.union([key])
        let withoutKey = promoted.subtracting([key])

        var pool = sorted
        var liveOnly: Bool?, liveWindows: Int?
        if coverage < minimumTrialCoverage {
            pool = sorted.filter { $0.features[key] != nil }
            liveOnly = true
            liveWindows = pool.count
            guard pool.count >= minimumLiveTrialWindows else {
                return TrialResult(gain: 0, margin: 0, coverage: coverage, windows: 0, liveOnly: true, liveWindows: pool.count)
            }
        }

        // A mark beyond the pool (history rebuilt smaller) starts over.
        let mark = lastMark.flatMap { $0 <= pool.count ? $0 : nil }
        let firstSplit = Int(Double(pool.count) * 0.8)
        let start: Int
        let counted: Bool
        if let mark, pool.count - mark >= freshWindowsPerTrial {
            start = mark
            counted = true
        } else if mark == nil, pool.count - firstSplit >= freshWindowsPerTrial {
            start = firstSplit
            counted = true
        } else {
            start = firstSplit
            counted = false
        }
        let fitSlice = Array(pool[..<start]), judged = Array(pool[start...])
        guard !fitSlice.isEmpty, !judged.isEmpty else {
            return TrialResult(gain: 0, margin: 0, coverage: coverage, windows: 0, liveOnly: liveOnly, liveWindows: liveWindows)
        }
        let anchor = fitSlice.last?.time ?? .now
        let with = fit(fitSlice, excluding: excluded, promoted: withKey, now: anchor, regularization: lambda)
        let without = fit(fitSlice, excluding: excluded, promoted: withoutKey, now: anchor, regularization: lambda)

        // Per-window log-loss improvement from having the signal.
        let diffs = judged.map { logLoss(without, $0, excluding: excluded) - logLoss(with, $0, excluding: excluded) }
        let n = Double(diffs.count)
        let mean = diffs.reduce(0, +) / n
        let variance = diffs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / max(n - 1, 1)
        return TrialResult(gain: mean, margin: zScore(forTests: testedSignals) * (variance / n).squareRoot(),
                           coverage: coverage, windows: diffs.count, liveOnly: liveOnly, liveWindows: liveWindows,
                           counted: counted, mark: counted ? pool.count : nil)
    }

    private static func logLoss(_ model: PredictionModel, _ sample: TrainingSample, excluding excluded: Set<FeatureKey>) -> Double {
        let p = min(max(model.probabilityUp(sample.features, excluding: excluded), 1e-6), 1 - 1e-6)
        return sample.wentUp ? -log(p) : -log(1 - p)
    }

    /// Picks the prior-pull strength whose fit best predicts the newest quarter of `samples`.
    static func tuneRegularization(_ samples: [TrainingSample], excluding excluded: Set<FeatureKey>,
                                   promoted: Set<FeatureKey> = []) -> Double {
        let split = Int(Double(samples.count) * 0.75)
        let fitSlice = Array(samples[..<split])
        let validation = Array(samples[split...])
        guard !fitSlice.isEmpty, !validation.isEmpty else { return defaultRegularization }
        let anchor = fitSlice.last?.time ?? .now
        let losses = regularizationCandidates.map { lambda in
            (lambda, score(fit(fitSlice, excluding: excluded, promoted: promoted, now: anchor, regularization: lambda),
                           on: validation, excluding: excluded).logLoss)
        }
        return losses.min { $0.1 < $1.1 }?.0 ?? defaultRegularization
    }

    static func score(_ model: PredictionModel, on samples: [TrainingSample], excluding excluded: Set<FeatureKey>)
        -> (accuracy: Double, brier: Double, logLoss: Double) {
        guard !samples.isEmpty else { return (0, 0, 0) }
        var correct = 0, brier = 0.0, logLoss = 0.0
        for s in samples {
            let p = min(max(model.probabilityUp(s.features, excluding: excluded), 1e-6), 1 - 1e-6)
            if (p >= 0.5) == s.wentUp { correct += 1 }
            let y = s.wentUp ? 1.0 : 0.0
            brier += (p - y) * (p - y)
            logLoss -= y * log(p) + (1 - y) * log(1 - p)
        }
        let n = Double(samples.count)
        return (Double(correct) / n, brier / n, logLoss / n)
    }

    /// Regularized, recency-weighted logistic regression solved with Newton's method.
    ///
    /// Maximizes Σ wᵢ·loglik(yᵢ | θ·xᵢ) − (λ/2)·‖θ − θ₀‖², where θ₀ are the starting weights
    /// and wᵢ = 0.5^(ageᵢ / halfLife). The prior pull keeps a small or noisy history from
    /// producing extreme weights; as history grows, the data dominates. A feature that's
    /// missing from a sample (e.g. tick momentum on rebuilt history) contributes nothing and
    /// its weight is learned only from samples that have it.
    static func fit(_ samples: [TrainingSample], excluding excluded: Set<FeatureKey>, promoted: Set<FeatureKey> = [],
                    now: Date = .now, halfLifeDays: Double = 14, regularization lambda: Double = defaultRegularization,
                    iterations: Int = 25) -> PredictionModel {
        let starting = PredictionModel.starting(excluding: excluded, promoted: promoted)
        let keys = starting.activeKeys.filter { !excluded.contains($0) }
        let dimension = keys.count + 1   // index 0 is the bias
        let prior = [0.0] + keys.map { $0.priorWeight(marketAnchored: starting.marketAnchored) }
        var theta = prior

        let rows: [(x: [Double], y: Double, weight: Double)] = samples.map { s in
            let age = max(now.timeIntervalSince(s.time), 0) / 86_400
            return ([1.0] + keys.map { s.features[$0] ?? 0 }, s.wentUp ? 1 : 0, pow(0.5, age / halfLifeDays))
        }
        guard !rows.isEmpty else { return starting }

        for _ in 0..<iterations {
            // Gradient of the (negated) objective and its Hessian.
            var gradient = (0..<dimension).map { lambda * (theta[$0] - prior[$0]) }
            var hessian = (0..<dimension).map { i in (0..<dimension).map { j in i == j ? lambda : 0 } }
            for row in rows {
                let z = zip(theta, row.x).reduce(0) { $0 + $1.0 * $1.1 }
                let p = 1 / (1 + exp(-z))
                let residual = row.weight * (p - row.y)
                let curvature = row.weight * p * (1 - p)
                for i in 0..<dimension where row.x[i] != 0 {
                    gradient[i] += residual * row.x[i]
                    for j in i..<dimension where row.x[j] != 0 {
                        hessian[i][j] += curvature * row.x[i] * row.x[j]
                    }
                }
            }
            for i in 0..<dimension { for j in 0..<i { hessian[i][j] = hessian[j][i] } }

            guard let step = solve(hessian, gradient) else { break }
            for i in 0..<dimension { theta[i] -= step[i] }
            if step.reduce(0, { max($0, abs($1)) }) < 1e-7 { break }
        }

        var model = starting
        model.bias = theta[0]
        for (index, key) in keys.enumerated() {
            model.weights[key.rawValue] = theta[index + 1]
        }
        model.trainingCount = samples.count
        model.trainedAt = now
        return model
    }

    /// Solves A·x = b by Gaussian elimination with partial pivoting.
    static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        let n = b.count
        var m = a
        var v = b
        for col in 0..<n {
            guard let pivot = (col..<n).max(by: { abs(m[$0][col]) < abs(m[$1][col]) }),
                  abs(m[pivot][col]) > 1e-12 else { return nil }
            m.swapAt(col, pivot)
            v.swapAt(col, pivot)
            for row in (col + 1)..<n {
                let factor = m[row][col] / m[col][col]
                guard factor != 0 else { continue }
                for k in col..<n { m[row][k] -= factor * m[col][k] }
                v[row] -= factor * v[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = v[row]
            for k in (row + 1)..<n { sum -= m[row][k] * x[k] }
            x[row] = sum / m[row][row]
        }
        return x
    }
}
