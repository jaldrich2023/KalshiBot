//
//  Theme.swift
//  KalshiBot
//
//  Shared visual language: the window backdrop, Liquid Glass cards, and type styles.
//

import SwiftUI

enum Theme {
    static let cardRadius: CGFloat = 18
    static let spacing: CGFloat = 16
}

/// The branded backdrop behind all content. It's a busy, bright image, so a dimming
/// gradient sits on top: Liquid Glass picks up its color and depth while the
/// cards' text stays legible (Apple's guidance for glass over rich backgrounds).
struct AppBackground: View {
    var body: some View {
        Image("AppBackground")
            .resizable()
            .aspectRatio(contentMode: .fill)
            .overlay {
                LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.7)],
                               startPoint: .top, endPoint: .bottom)
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

/// A content card on Liquid Glass with an icon + small-caps header.
struct Panel<Content: View>: View {
    let title: String
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(title: title, systemImage: systemImage)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassCard()
    }
}

struct CardHeader: View {
    let title: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(.tint)
            }
            Text(title.uppercased())
                .tracking(0.8)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// Regular Liquid Glass in the card shape, plus a hairline highlight along the top
    /// edge so cards read as distinct panes over the dark backdrop.
    func glassCard(radius: CGFloat = Theme.cardRadius) -> some View {
        self
            .glassEffect(.regular, in: .rect(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0.02)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
    }

    /// Lays out at the size of `template` — the fullest version of this content,
    /// rendered invisibly — so the card never resizes as data arrives, disappears,
    /// or changes length.
    func reservingSpace<Template: View>(@ViewBuilder for template: () -> Template) -> some View {
        ZStack(alignment: .topLeading) {
            template()
                .hidden()
                .accessibilityHidden(true)
            self
        }
    }

    /// Large rounded numerals for headline figures.
    func heroNumber(size: CGFloat = 30) -> some View {
        self
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText())
    }
}

/// Toolbar pill showing whether the bot is collecting and predicting.
struct StatusPill: View {
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isRunning ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
                .shadow(color: isRunning ? .green.opacity(0.8) : .clear, radius: 4)
            Text(isRunning ? "Live" : "Paused")
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isRunning ? "Bot is live" : "Bot is paused")
    }
}

/// Which way a signal points: green for Up, red for Down, grey when neutral. Always
/// paired with an arrow and a word, so direction never relies on color alone.
struct DirectionPill: View {
    /// Positive favors Up, negative favors Down.
    let value: Double
    var verb = "Favors"
    var neutralBelow = 0.1

    var body: some View {
        let isNeutral = abs(value) < neutralBelow
        let up = value > 0
        let side = up ? "Up" : "Down"
        Label(isNeutral ? "Neutral" : (verb.isEmpty ? side : "\(verb) \(side)"),
              systemImage: isNeutral ? "arrow.left.and.right" : (up ? "arrow.up.right" : "arrow.down.right"))
            .font(.caption.weight(.semibold))
            .foregroundStyle(isNeutral ? Color.secondary : (up ? Color.green : Color.red))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background((isNeutral ? Color.white : (up ? Color.green : Color.red)).opacity(0.14), in: .capsule)
    }
}
