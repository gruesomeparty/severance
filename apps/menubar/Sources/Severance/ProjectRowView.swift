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
                HStack(spacing: 6) {
                    Text(project.name).font(.system(size: 13, weight: .semibold))
                    if !sessionLabel.isEmpty {
                        Text(sessionLabel).font(.mono(9.5)).foregroundStyle(palette.inkMute)
                    }
                    Spacer()
                    HStack(spacing: 5) {
                        Chip(text: project.priority.chipLabel, color: priorityColor,
                             filled: project.priority == .critical)
                        Chip(text: statusLabel, color: ledColor, filled: project.status != .active)
                    }
                }
                Text(meta).font(.mono(10)).foregroundStyle(palette.inkMute)
                if let limit = project.limitUsd, limit > 0,
                   project.status == .active || project.status == .paused {
                    costBar(limit: limit)
                }
                actionLine
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
        .contextMenu {
            if project.status == .active {
                Button("Sever now") { store.severNow(project) }
            } else {
                Button("Resume now") { store.resumeNow(project) }
            }
            if project.status != .active {
                Button("Open handover…") { store.openHandover(project) }
            }
        }
    }

    // MARK: action line (primary buttons)

    @ViewBuilder private var actionLine: some View {
        HStack(spacing: 8) {
            switch project.status {
            case .severed:
                Text(resumeCountdown).font(.mono(10)).foregroundStyle(palette.amber)
            case .paused:
                Text(project.reason == .preempted ? "preempted" : "paused")
                    .font(.mono(10)).foregroundStyle(palette.amber)
            default:
                EmptyView()
            }
            Spacer(minLength: 0)
            if project.status == .active {
                pill("Sever", tint: palette.severed) { store.severNow(project) }
            } else {
                pill(project.status == .severed ? "Resume now" : "Resume", tint: palette.accent) {
                    store.resumeNow(project)
                }
            }
        }
        .padding(.top, 2)
    }

    private func pill(_ title: String, tint: Color, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(tint.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(tint.opacity(0.5), lineWidth: 1))
    }

    private func costBar(limit: Double) -> some View {
        let frac = min(1.0, (project.sessionCostUsd ?? 0) / limit)
        let hot = project.status == .paused
        return GeometryReader { geo in
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

    // Two sessions of one repo render as two rows sharing a slug; a short session
    // marker keeps them distinguishable (issue #15). Prefer the tmux pane (e.g.
    // %12) once set, else a truncated session id.
    private var sessionLabel: String {
        if let pane = project.tmuxPane, !pane.isEmpty { return pane }
        if let sid = project.sessionId, !sid.isEmpty { return String(sid.prefix(8)) }
        return ""
    }

    private var statusLabel: String {
        switch project.status {
        case .active: return "Active"
        case .severed: return "Severed"
        case .paused: return "Paused"
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

    private var resumeCountdown: String {
        guard let d = project.resumeAtDate else { return "awaiting reset" }
        let secs = max(0, Int(d.timeIntervalSinceNow))
        if secs == 0 { return "resuming…" }
        let h = secs / 3600, m = (secs % 3600) / 60
        return "returns to the floor in \(h)h \(m)m"
    }
}
