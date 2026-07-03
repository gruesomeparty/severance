import SeveranceCore
import SwiftUI

// One "refinement quota" well (5h or 7d). Navy in both themes with bright cyan
// serif numerals; ticks fill with utilization and carry a red dashed threshold mark.
struct GaugeBinView: View {
    let palette: Palette
    let label: String
    let util: Double?
    let resetsAt: Date?
    let weekly: Bool
    let warnThreshold: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let tickCount = 24

    private var warn: Bool { (util ?? 0) >= warnThreshold }
    private var numeral: Color { warn ? palette.wellAmber : palette.wellInk }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(2.0)
                .foregroundStyle(Color(hex: 0x46647D))

            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(util.map { "\(Int($0.rounded()))" } ?? "—")
                    .font(.serifNumerals(38))
                    .foregroundStyle(numeral)
                    .shadow(color: numeral.opacity(0.55), radius: 7)
                Text("%")
                    .font(.serifNumerals(17))
                    .foregroundStyle(palette.wellInkDim)
            }
            .monospacedDigit()

            ticks

            Text(resetText)
                .font(.mono(10))
                .foregroundStyle(Color(hex: 0x46647D))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9).fill(palette.well)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9).stroke(palette.wellBorder, lineWidth: 1)
        )
    }

    private var filled: Int {
        guard let util else { return 0 }
        return max(0, min(tickCount, Int((util / 100 * Double(tickCount)).rounded())))
    }

    private var thresholdIndex: Int {
        max(0, min(tickCount - 1, Int((warnThreshold / 100 * Double(tickCount)).rounded())))
    }

    private var ticks: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<tickCount, id: \.self) { i in
                if i == thresholdIndex {
                    Rectangle()
                        .fill(palette.wellRedTick)
                        .frame(width: 1)
                } else {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(i < filled
                            ? (warn ? palette.wellAmber : palette.wellInkDim)
                            : Color(hex: 0x9FE8FF, alpha: 0.12))
                }
            }
        }
        .frame(height: 13)
    }

    private var resetText: String {
        guard let resetsAt else { return "resets —" }
        let df = DateFormatter()
        if weekly {
            df.dateFormat = "EEE HH:mm"
            return "resets \(df.string(from: resetsAt))"
        }
        df.dateFormat = "HH:mm"
        let secs = max(0, Int(resetsAt.timeIntervalSinceNow))
        let h = secs / 3600, m = (secs % 3600) / 60
        return "resets \(df.string(from: resetsAt)) · in \(h)h \(m)m"
    }
}
