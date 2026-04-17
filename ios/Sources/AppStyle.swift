import SwiftUI
import UIKit

enum AppPalette {
    static let backgroundTop = dynamic(
        light: UIColor(red: 0.97, green: 0.985, blue: 1.0, alpha: 1.0),
        dark: UIColor(red: 0.15, green: 0.16, blue: 0.18, alpha: 1.0)
    )
    static let backgroundBottom = dynamic(
        light: UIColor(red: 0.90, green: 0.95, blue: 1.0, alpha: 1.0),
        dark: UIColor(red: 0.11, green: 0.115, blue: 0.125, alpha: 1.0)
    )

    static let panel = dynamic(
        light: UIColor(red: 0.985, green: 0.992, blue: 1.0, alpha: 0.92),
        dark: UIColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 0.82)
    )
    static let elevatedPanel = dynamic(
        light: UIColor.white.withAlphaComponent(0.96),
        dark: UIColor(red: 0.15, green: 0.16, blue: 0.19, alpha: 0.92)
    )
    static let mutedPanel = dynamic(
        light: UIColor(red: 0.93, green: 0.96, blue: 1.0, alpha: 0.82),
        dark: UIColor(red: 0.18, green: 0.19, blue: 0.22, alpha: 0.78)
    )
    static let border = dynamic(
        light: UIColor(red: 0.79, green: 0.86, blue: 0.97, alpha: 0.72),
        dark: UIColor.white.withAlphaComponent(0.08)
    )
    static let accent = Color(red: 0.12, green: 0.47, blue: 0.96)
    static let accentMuted = dynamic(
        light: UIColor(red: 0.84, green: 0.91, blue: 1.0, alpha: 0.95),
        dark: UIColor(red: 0.16, green: 0.22, blue: 0.31, alpha: 0.95)
    )

    static let primaryText = dynamic(
        light: UIColor(red: 0.08, green: 0.10, blue: 0.14, alpha: 1.0),
        dark: UIColor.white.withAlphaComponent(0.96)
    )
    static let secondaryText = dynamic(
        light: UIColor(red: 0.34, green: 0.40, blue: 0.49, alpha: 1.0),
        dark: UIColor.white.withAlphaComponent(0.68)
    )
    static let tertiaryText = dynamic(
        light: UIColor(red: 0.50, green: 0.56, blue: 0.65, alpha: 1.0),
        dark: UIColor.white.withAlphaComponent(0.44)
    )

    static let dockFill = dynamic(
        light: UIColor.white.withAlphaComponent(0.88),
        dark: UIColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 0.82)
    )
    static let shadow = dynamic(
        light: UIColor.black.withAlphaComponent(0.10),
        dark: UIColor.black.withAlphaComponent(0.28)
    )

    static let warning = Color.orange
    static let success = Color.green
    static let danger = Color.red

    static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? dark : light
        })
    }
}

enum AppMotion {
    static func quick(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.14)
    }

    static func standard(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.18)
    }

    static func drawer(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.22)
    }

    static func scroll(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.2)
    }

    static var fade: AnyTransition {
        .opacity
    }

    static var fadeScale: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.985))
    }
}

struct GlassCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(AppPalette.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(AppPalette.border, lineWidth: 1)
            )
            .compositingGroup()
            .shadow(color: AppPalette.shadow, radius: 12, y: 8)
    }
}

struct HelmSurfaceHeaderChip: Identifiable {
    let id: String
    let title: String
    let tint: Color

    init(_ title: String, tint: Color = AppPalette.secondaryText) {
        self.id = title
        self.title = title
        self.tint = tint
    }
}

struct HelmSurfaceHeader: View {
    let eyebrow: String
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color
    let chips: [HelmSurfaceHeaderChip]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(eyebrow)
                        .font(.system(.caption2, design: .rounded, weight: .bold))
                        .foregroundStyle(AppPalette.secondaryText)
                        .textCase(.uppercase)

                    Text(title)
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(AppPalette.primaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if !detail.isEmpty {
                        Text(detail)
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(AppPalette.secondaryText)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }

            if !chips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(chips) { chip in
                            Text(chip.title)
                                .font(.system(.caption2, design: .rounded, weight: .semibold))
                                .foregroundStyle(chip.tint)
                                .lineLimit(1)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(chip.tint.opacity(0.10), in: Capsule())
                        }
                    }
                }
                .scrollClipDisabled()
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionSurface(cornerRadius: 20)
        .accessibilityElement(children: .combine)
    }
}

private struct KeyboardDismissDownSwipeModifier: ViewModifier {
    var minimumDistance: CGFloat
    var verticalThreshold: CGFloat

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                DragGesture(minimumDistance: minimumDistance)
                    .onEnded { value in
                        let verticalOffset = value.translation.height
                        guard verticalOffset > verticalThreshold else { return }
                        guard verticalOffset > abs(value.translation.width) else { return }
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil,
                            from: nil,
                            for: nil
                        )
                    }
            )
    }
}

struct StableSessionPreviewBlock: View {
    let threadID: String
    let preview: String
    let isLive: Bool
    let font: Font
    let foregroundColor: Color
    let lineLimit: Int
    var panelPadding: CGFloat? = nil

    @State private var displayedPreview = ""

    private var trimmedIncomingPreview: String {
        preview.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedDisplayedPreview: String {
        displayedPreview.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visiblePreview: String {
        if !trimmedDisplayedPreview.isEmpty {
            return displayedPreview
        }
        return trimmedIncomingPreview
    }

    var body: some View {
        Group {
            if !visiblePreview.isEmpty {
                previewText(visiblePreview)
            }
        }
        .transaction { transaction in
            transaction.animation = nil
        }
        .onAppear {
            syncPreview(reset: displayedPreview.isEmpty)
        }
        .onChange(of: threadID) { _, _ in
            displayedPreview = trimmedIncomingPreview
        }
        .onChange(of: preview) { _, _ in
            syncPreview(reset: false)
        }
        .onChange(of: isLive) { _, nowLive in
            if !nowLive || displayedPreview.isEmpty {
                displayedPreview = trimmedIncomingPreview
            }
        }
    }

    private func syncPreview(reset: Bool) {
        if reset || !isLive || trimmedDisplayedPreview.isEmpty {
            displayedPreview = trimmedIncomingPreview
        }
    }

    @ViewBuilder
    private func previewText(_ text: String) -> some View {
        if let panelPadding {
            Text(text)
                .font(font)
                .foregroundStyle(foregroundColor)
                .lineLimit(lineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(panelPadding)
                .background(AppPalette.mutedPanel.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            Text(text)
                .font(font)
                .foregroundStyle(foregroundColor)
                .lineLimit(lineLimit)
        }
    }
}

extension View {
    func glassCard() -> some View {
        modifier(GlassCardModifier())
    }

    func dismissesKeyboardOnDownSwipe(
        minimumDistance: CGFloat = 12,
        verticalThreshold: CGFloat = 18
    ) -> some View {
        modifier(
            KeyboardDismissDownSwipeModifier(
                minimumDistance: minimumDistance,
                verticalThreshold: verticalThreshold
            )
        )
    }

    func appBackground() -> some View {
        background(
            ZStack {
                LinearGradient(
                    colors: [AppPalette.backgroundTop, AppPalette.backgroundBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                RadialGradient(
                    colors: [
                        AppPalette.accent.opacity(0.12),
                        Color.clear
                    ],
                    center: .topTrailing,
                    startRadius: 24,
                    endRadius: 320
                )
                .offset(x: 48, y: -120)
            }
            .ignoresSafeArea()
        )
    }

    func darkPanel(cornerRadius: CGFloat = 22) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(AppPalette.elevatedPanel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(AppPalette.border, lineWidth: 1)
        )
    }

    func sectionSurface(cornerRadius: CGFloat = 18) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(AppPalette.elevatedPanel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(AppPalette.border, lineWidth: 1)
        )
    }

    func recessedSurface(cornerRadius: CGFloat = 18) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(AppPalette.mutedPanel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(AppPalette.border, lineWidth: 1)
        )
    }

    func subtleActionCapsule() -> some View {
        background(AppPalette.mutedPanel, in: Capsule())
        .overlay(
            Capsule()
                .stroke(AppPalette.border, lineWidth: 1)
        )
    }

    func tintedCapsule(tint: Color) -> some View {
        background(tint.opacity(0.12), in: Capsule())
        .overlay(
            Capsule()
                .stroke(tint.opacity(0.18), lineWidth: 1)
        )
    }

    func inputFieldSurface(cornerRadius: CGFloat = 18) -> some View {
        background(AppPalette.elevatedPanel, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(AppPalette.border, lineWidth: 1)
        )
    }
}
