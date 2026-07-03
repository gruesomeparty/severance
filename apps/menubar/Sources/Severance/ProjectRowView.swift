import SeveranceCore
import SwiftUI

struct Chip: View {
    let text: String
    let color: Color
    var filled: Bool = false
    var body: some View {
        Text(text)
            .font(.mono(8.5, weight: .medium))
            .tracking(1)
            .textCase(.uppercase)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(RoundedRectangle(cornerRadius: 4).fill(filled ? color.opacity(0.12) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(color, lineWidth: 1))
    }
}

struct ProjectRowView: View {
    let palette: Palette
    let project: ProjectState
    @EnvironmentObject var store: SeveranceStore

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(ledColor).frame(width: 7, height: 7).padding(.top, 5)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(project.name).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    HStack(spacing: 5) {
                        Chip(text: project.priority.chipLabel, color: priorityColor,
                             filled: project.priority == .critical)
                        Chip(text: statusLabel, color: ledColor, filled: project.status != .active)
                    }
                }
                Text(meta).font(.mono(10)).foregroundStyle(palette.inkMute)
                trailing
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
    }

    // MARK: derived

    private var ledColor: Color {
        switch project.status {
        case .active: return palette.ok
        case .severed: return palette.severed
        case .paused: return palette.amber
        case .orphaned: return palette.inkMute
        }
    }

    private var priorityColor: Color {
        switch project.priority {
        case .critical: return palette.accent
        case .high: return palette.inkSoft
        case .normal, .low: return palette.inkMute
        }
    }

    private var statusLabel: String {
        switch project.status {
        case .active: return "Active"
        case .severed: return "Severed"
        case .paused: return project.reason == .preempted ? "Paused" : "Paused"
        case .orphaned: return "Orphaned"
        }
    }

    private var meta: String {
        func money(_ v: Double?) -> String { v.map { String(format: "$%.2f", $0) } ?? "$0.00" }
        switch project.status {
        case .active:
            if let limit = project.limitUsd {
                return "\(money(project.sessionCostUsd)) / \(money(limit))"
            }
            return "\(money(project.sessionCostUsd)) this session · outie budget"
        case .severed:
            let u = project.utilizationAtTrip.map { " · \(project.reason?.rawValue ?? "util") \(Int($0))%" } ?? ""
            return "severed\(u) · handover ✓"
        case .paused:
            if let by = project.preemptedBy { return "preempted by \(by) · \(money(project.sessionCostUsd)) / \(money(project.limitUsd))" }
            return "manually paused"
        case .orphaned:
            return "orphaned · original pane is gone"
        }
    }

    // Cost bar for budgeted running projects; resume line for severed ones.
    @ViewBuilder private var trailing: some View {
        if project.status == .severed {
            HStack {
                Text(resumeCountdown).font(.mono(10)).foregroundStyle(palette.amber)
                Spacer()
                Button("Resume now") { store.resumeNow(project) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(palette.accentBG))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(palette.accentBorder, lineWidth: 1))
            }
            .padding(.top, 2)
        } else if let limit = project.limitUsd, limit > 0 {
            let frac = min(1.0, (project.sessionCostUsd ?? 0) / limit)
            let hot = project.status == .paused
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.barBG)
                    Capsule().fill(hot ? palette.amber : palette.accentDim)
                        .frame(width: geo.size.width * frac)
                    Rectangle().fill(palette.severed).frame(width: 1, height: 8)
                        .position(x: geo.size.width, y: 4)
                }
            }
            .frame(height: 3)
            .padding(.top, 4)
        }
    }

    private var resumeCountdown: String {
        guard let d = project.resumeAtDate else { return "awaiting reset" }
        let secs = max(0, Int(d.timeIntervalSinceNow))
        if secs == 0 { return "resuming…" }
        let h = secs / 3600, m = (secs % 3600) / 60
        return "returns to the floor in \(h)h \(m)m"
    }
}
