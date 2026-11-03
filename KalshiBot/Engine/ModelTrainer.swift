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

    var hasEnoughData: Bool {
        if liveOnly == true { return (liveWindows ?? 0) >= ModelTrainer.minimumLiveTrialWindows }
        return coverage >= ModelTrainer.minimumTrialCoverage
    }
    /// Helps by more than its margin of error.
    var isSignificantGain: Bool { hasEnoughData && gain > margin }
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
}

nonisolated enum ModelTrainer {

    /// Minimum settled windows before a holdout split is meaningful.
    static let minimumForEvaluation = 60

    /// Prior-pull strengths tried during tuning, weakest to strongest (in units of windows).
    static let regularizationCandidates: [Double] = [10, 30, 100, 300, 1000]
    /// Used before there's enough history to tune.
    static let defaultRegularization: Double = 300

    /// Walk-forward training:
    /// 1. Split history by time: oldest 80% train, newest 20% holdout.
    /// 2. Tune the prior-pull strength on the newest quarter of the training slice.
    /// 3. Score the tuned model and the starting weights on the untouched holdout.
    /// 4. Trial each context signal on the same holdout (see `trial`).
    /// 5. Refit on everything — but only deploy the learned weights if they beat the
    ///    starting weights out of sample. Otherwise keep predicting with the starting
    ///    weights until more history makes learning pay off.
    ///
    /// A market-anchored model only learns from windows where Kalshi's odds are known;
    /// a window without them would look like "the market said 50/50" and skew the fit.
    static func train(_ samples: [TrainingSample], excluding excluded: Set<FeatureKey>,
                      promoted: Set<FeatureKey> = [], now: Date = .now) -> PredictionModel {
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

        let split = Int(Double(sorted.count) * 0.8)
        let train = Array(sorted[..<split])
        let holdout = Array(sorted[split...])
        let lambda = tuneRegularization(train, excluding: excluded, promoted: promoted)

        // Recency weighting is anchored at the end of the training slice, so the
        // holdout is scored exactly as if it were the future.
        let anchor = train.last?.time ?? now
        let trained = fit(train, excluding: excluded, promoted: promoted, now: anchor, regularization: lambda)
        let fitted = score(trained, on: holdout, excluding: excluded)
        let prior = score(starting, on: holdout, excluding: excluded)
        let learnedHelps = fitted.logLoss < prior.logLoss

        // Recency is measured from the newest window, not the wall clock, so history
        // doesn't fade away just because the app wasn't running for a while.
        var model = learnedHelps
            ? fit(sorted, excluding: excluded, promoted: promoted, now: sorted.last?.time ?? now, regularization: lambda)
            : starting
        model.trainingCount = sorted.count
        model.trainedAt = now
        model.usesLearnedWeights = learnedHelps
        model.evaluation = ModelEvaluation(
            holdoutCount: holdout.count,
            accuracy: fitted.accuracy, brierScore: fitted.brier,
            priorAccuracy: prior.accuracy, priorBrierScore: prior.brier,
            regularization: lambda
        )
        for key in FeatureKey.promotionCandidates where !excluded.contains(key) {
            model.trials[key.rawValue] = trial(key, train: train, holdout: holdout, baseline: trained,
                                               excluding: excluded, promoted: promoted, lambda: lambda, anchor: anchor)
        }
        return model
    }

    /// Fraction of windows a trial signal must be present in to be judged fairly.
    static let minimumTrialCoverage = 0.5
    /// A signal present in fewer windows (live-only ones like tick momentum) is trialled
    /// on just the windows that have it, once there are this many (~5 days live).
    static let minimumLiveTrialWindows = 500

    /// Tests whether `key` earns its place: refits on the training slice with the signal
    /// added (or, if already promoted, removed) and compares the two models window by
    /// window on the holdout. A positive `gain` means the model with the signal predicts
    /// better; it's significant only if larger than its 95% margin.
    static func trial(_ key: FeatureKey, train: [TrainingSample], holdout: [TrainingSample], baseline: PredictionModel,
                      excluding excluded: Set<FeatureKey>, promoted: Set<FeatureKey>, lambda: Double, anchor: Date) -> TrialResult {
        let coverage = Double(train.count { $0.features[key] != nil }) / Double(max(train.count, 1))
        let isPromoted = promoted.contains(key)
        let withKey = isPromoted ? promoted : promoted.union([key])
        let withoutKey = promoted.subtracting([key])

        var trialHoldout = holdout
        let with: PredictionModel, without: PredictionModel
        var liveOnly: Bool?, liveWindows: Int?
        if coverage >= minimumTrialCoverage {
            let alternative = fit(train, excluding: excluded, promoted: isPromoted ? withoutKey : withKey,
                                  now: anchor, regularization: lambda)
            (with, without) = isPromoted ? (baseline, alternative) : (alternative, baseline)
        } else {
            // Sparse signal: compare both models on only the windows that have it,
            // oldest 70% to fit, newest 30% to judge.
            let having = (train + holdout).filter { $0.features[key] != nil }.sorted { $0.time < $1.time }
            liveOnly = true
            liveWindows = having.count
            guard having.count >= minimumLiveTrialWindows else {
                return TrialResult(gain: 0, margin: 0, coverage: coverage, windows: 0, liveOnly: true, liveWindows: having.count)
            }
            let split = Int(Double(having.count) * 0.7)
            let fitSlice = Array(having[..<split])
            trialHoldout = Array(having[split...])
            let sliceAnchor = fitSlice.last?.time ?? anchor
            with = fit(fitSlice, excluding: excluded, promoted: withKey, now: sliceAnchor, regularization: lambda)
            without = fit(fitSlice, excluding: excluded, promoted: withoutKey, now: sliceAnchor, regularization: lambda)
        }
        // Per-window log-loss improvement from having the signal.
        let diffs = trialHoldout.map { logLoss(without, $0, excluding: excluded) - logLoss(with, $0, excluding: excluded) }
        let n = Double(diffs.count)
        let mean = diffs.reduce(0, +) / n
        let variance = diffs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / max(n - 1, 1)
        return TrialResult(gain: mean, margin: 1.96 * (variance / n).squareRoot(), coverage: coverage, windows: diffs.count,
                           liveOnly: liveOnly, liveWindows: liveWindows)
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
