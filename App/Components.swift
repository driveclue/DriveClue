import DriveClueCore
import SwiftUI

struct DiagnosticBar: View {
    var value: Double
    var color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.25))
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: geometry.size.width * min(max(value / 100, 0), 1))
            }
        }
        .frame(height: 10)
        .accessibilityLabel("\(Int(value)) percent")
    }
}

struct RatingCard: View {
    var title: String
    var value: Double
    var band: HealthBand

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 206, alignment: .leading)
            Text(band.title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 64, height: 20)
                .background(IndicatorStyle.color(band), in: RoundedRectangle(cornerRadius: 4))
            DiagnosticBar(value: value, color: IndicatorStyle.color(band))
                .frame(maxWidth: 250)
            Text(String(format: "%.1f%%", value))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .frame(width: 58, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(band.title) \(Int(value)) percent")
    }
}

/// A stable horizontal throughput readout. Unlike the former dial, its scale
/// is explicit and the animated fill always maps directly to the measured MB/s.
struct BenchmarkThroughputBar: View {
    var title: String
    var speed: Double
    var maximum: Double
    var color: Color
    var isActive: Bool

    private var normalized: Double {
        min(max(speed / max(maximum, 1), 0), 1)
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(color)
                .opacity(isActive ? 1 : 0.55)
                .animation(.easeInOut(duration: 0.35), value: isActive)
                .frame(width: 58, alignment: .leading)

            VStack(alignment: .leading, spacing: 5) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.black.opacity(0.32))
                        ForEach(0..<11, id: \.self) { tick in
                            Rectangle()
                                .fill(Color.white.opacity(tick.isMultiple(of: 5) ? 0.22 : 0.10))
                                .frame(width: 1, height: tick.isMultiple(of: 5) ? 18 : 11)
                                .offset(x: geometry.size.width * CGFloat(tick) / 10)
                        }
                        RoundedRectangle(cornerRadius: 5)
                            .fill(color)
                            .frame(width: geometry.size.width * normalized)
                            .opacity(isActive ? 1 : 0.65)
                            .shadow(color: color.opacity(isActive ? 0.70 : 0.25), radius: isActive ? 7 : 2)
                            .animation(.easeInOut(duration: 0.45), value: normalized)
                            .animation(.easeInOut(duration: 0.35), value: isActive)
                    }
                }
                .frame(height: 18)

                HStack {
                    Text("0")
                    Spacer()
                    Text(String(format: "%.0f MB/s", maximum))
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(DiagnosticTheme.muted)
            }

            VStack(alignment: .trailing, spacing: 0) {
                Text(String(format: "%.1f", speed))
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(DiagnosticTheme.text)
                    .contentTransition(.numericText(value: speed))
                    .animation(.easeInOut(duration: 0.35), value: speed)
                Text("MB/s")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(DiagnosticTheme.muted)
            }
            .frame(width: 90, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(String(format: "%.1f", speed)) megabytes per second")
    }
}

struct SectionHeader: View {
    var title: String
    var symbol: String
    var tint: Color = DiagnosticTheme.muted

    var body: some View {
        HStack(spacing: 7) {
            SectionHeadingIcon(symbol: symbol, tint: tint)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
        }
        .foregroundStyle(DiagnosticTheme.text)
        .padding(.vertical, 3)
    }
}

/// A compact multicolor symbol for content headings.
///
/// Icons8's color style keeps the color in the illustration itself. Palette
/// rendering gives the SF Symbol the same layered feel without adding a
/// second badge, ring, or tile around every heading.
struct SectionHeadingIcon: View {
    var symbol: String
    var tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 21, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(tint, paletteSecondary, paletteTertiary)
            .frame(width: 27, height: 27, alignment: .leading)
            .accessibilityHidden(true)
    }

    private var paletteSecondary: Color {
        switch symbol {
        case "checkmark.shield.fill", "checkmark.seal.fill": return .white
        case "heart.text.square.fill": return tint.opacity(0.7)
        case "thermometer.medium": return DiagnosticTheme.cyan
        case "stethoscope": return DiagnosticTheme.rose
        case "clock.fill", "clock.arrow.circlepath": return DiagnosticTheme.cyan
        case "gauge.with.dots.needle.67percent": return DiagnosticTheme.cyan
        default: return .white.opacity(0.9)
        }
    }

    private var paletteTertiary: Color {
        switch symbol {
        case "externaldrive.fill", "internaldrive.fill": return DiagnosticTheme.amber
        case "chart.xyaxis.line", "tablecells": return DiagnosticTheme.cyan
        case "info.circle.fill", "info.circle": return DiagnosticTheme.cyan
        case "heart.text.square.fill": return .white
        default: return tint.opacity(0.55)
        }
    }
}

extension View {
    /// Wraps a dashboard section in the standard padded panel card.
    func panel(padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DiagnosticTheme.panel, in: RoundedRectangle(cornerRadius: 7))
    }

    /// Column captions shared by the indicator, error, and self-test tables.
    func diagnosticTableHeader() -> some View {
        self
            .font(.system(size: 10, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(DiagnosticTheme.muted)
            .padding(.horizontal, 22)
            .frame(height: 27)
            .background(DiagnosticTheme.rowAlternate)
            .overlay(alignment: .bottom) { DiagnosticTheme.line.frame(height: 1) }
    }

    /// Alternating table row used by the error and self-test tables.
    func diagnosticTableRow(index: Int) -> some View {
        self
            .font(.system(size: 12))
            .foregroundStyle(DiagnosticTheme.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(index.isMultiple(of: 2) ? DiagnosticTheme.row : DiagnosticTheme.rowAlternate)
            .textSelection(.enabled)
    }
}
