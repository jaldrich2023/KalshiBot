//
//  AboutView.swift
//  KalshiBot
//

import SwiftUI
import AppKit

/// The About window, styled like the app: branded backdrop, glass card, and the license.
struct AboutView: View {
    private let version = AppVersion.current

    private var licenseText: String {
        Bundle.main.url(forResource: "License", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? "License text unavailable."
    }

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
                Text("Kalshi Bot")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("I'm The Team, LLC")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Version \(version.marketing) · Build \(version.build)")
                    .font(.callout.monospacedDigit())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .glassEffect(.regular, in: .capsule)
                    .textSelection(.enabled)
            }

            Text("Predicts whether each Kalshi 15-minute BTC window settles Up or Down, against the CF Benchmarks 60-second average, and tracks its accuracy on every window.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label(Self.privacyNote, systemImage: "hand.raised")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                CardHeader(title: "License", systemImage: "doc.text")
                ScrollView {
                    Text(licenseText)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 240)
                .scrollContentBackground(.hidden)
            }
            .padding(16)
            .glassCard()

            disclaimer

            Text(version.copyright)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(width: 560)
        .preferredColorScheme(.dark)
    }
}

extension AboutView {
    /// Plain-language summary of the disclaimer (DISCLAIMER.md).
    private var disclaimer: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(title: "Not financial advice", systemImage: "exclamationmark.shield")
            ForEach(Self.disclaimerPoints, id: \.self) { point in
                Label {
                    Text(point).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "circle.fill").font(.system(size: 4)).foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .accessibilityElement(children: .combine)
    }

    static let privacyNote = "Privacy: Kalshi Bot sends I'm The Team, LLC an anonymous install notice — a random id, the app version, macOS version, Mac model, locale and time zone — once per installation and about once a month; the server derives an approximate location (country, region, city) from the connection's IP address. Crash and bug reports are sent only if you turn them on in Settings or send one yourself. No personal data is sent."

    static let disclaimerPoints = [
        "For information only. Nothing here is financial, investment or trading advice, or a recommendation to buy or sell anything.",
        "Every call is a probability, not a certainty: a 70% call is expected to miss about 3 times in 10. Past accuracy doesn't guarantee future results.",
        "Event contracts carry a real risk of losing your entire stake. Every trading decision is yours.",
        "Not affiliated with or endorsed by Kalshi or CF Benchmarks.",
    ]
}

/// Opens the About window from the app menu (replacing the standard About panel).
struct AboutCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About Kalshi Bot") { openWindow(id: AboutView.windowID) }
    }
}

extension AboutView {
    static let windowID = "about"
}

#Preview {
    AboutView()
}
