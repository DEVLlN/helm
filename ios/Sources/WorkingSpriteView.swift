import SwiftUI

// Frame presets adapted from the MIT-licensed rattles spinner library:
// https://github.com/vyfor/rattles
enum HelmSpinnerPreset {
    case dots
    case dots2
    case rollingLine
    case point

    var frames: [String] {
        switch self {
        case .dots:
            return ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        case .dots2:
            return ["⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷"]
        case .rollingLine:
            return ["/", "-", "\\", "|", "\\", "-"]
        case .point:
            return ["···", "•··", "·•·", "··•", "···"]
        }
    }

    var interval: TimeInterval {
        switch self {
        case .dots, .dots2, .rollingLine:
            return 0.08
        case .point:
            return 0.20
        }
    }
}

struct WorkingSpriteView: View {
    var preset: HelmSpinnerPreset = .dots
    var tint: Color = AppPalette.accent
    var font: Font = .system(.caption, design: .monospaced, weight: .semibold)
    var accessibilityLabel: String = "Working"

    var body: some View {
        TimelineView(.animation(minimumInterval: preset.interval, paused: false)) { context in
            Text(frame(for: context.date))
                .font(font)
                .foregroundStyle(tint)
                .monospacedDigit()
        }
        .frame(minWidth: minimumWidth, minHeight: 12, alignment: .center)
        .accessibilityLabel(accessibilityLabel)
    }

    private var minimumWidth: CGFloat {
        CGFloat(max(preset.frames.map(\.count).max() ?? 1, 1) * 10)
    }

    private func frame(for date: Date) -> String {
        let frames = preset.frames
        let index = Int(date.timeIntervalSinceReferenceDate / preset.interval) % frames.count
        return frames[index]
    }
}

struct WaitingWaveSpriteView: View {
    var tint: Color = AppPalette.secondaryText
    var font: Font = .system(.caption, design: .monospaced, weight: .bold)
    var accessibilityLabel: String = "Waiting"

    private let interval: TimeInterval = 0.12
    private let opacityFrames: [[Double]] = [
        [1.00, 0.40, 0.18],
        [0.72, 1.00, 0.32],
        [0.32, 0.72, 1.00],
        [0.18, 0.32, 0.72],
        [0.32, 0.18, 0.32],
        [0.72, 0.32, 0.18],
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: interval, paused: false)) { context in
            let frame = opacityFrame(for: context.date)

            HStack(spacing: 1) {
                ForEach(0..<frame.count, id: \.self) { index in
                    Text("\u{2022}")
                        .opacity(frame[index])
                }
            }
            .font(font)
            .foregroundStyle(tint)
            .monospacedDigit()
        }
        .frame(minWidth: 30, minHeight: 12, alignment: .center)
        .accessibilityLabel(accessibilityLabel)
    }

    private func opacityFrame(for date: Date) -> [Double] {
        let index = Int(date.timeIntervalSinceReferenceDate / interval) % opacityFrames.count
        return opacityFrames[index]
    }
}

struct WorkingStatusLabel: View {
    let text: String
    var preset: HelmSpinnerPreset = .dots2
    var tint: Color = AppPalette.secondaryText
    var font: Font = .system(.caption, design: .monospaced, weight: .semibold)

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            WorkingSpriteView(
                preset: preset,
                tint: tint,
                font: font,
                accessibilityLabel: text
            )

            Text(text)
                .font(font)
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
