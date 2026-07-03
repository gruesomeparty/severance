import AppKit
import SeveranceCore
import SwiftUI

struct PanelView: View {
    @EnvironmentObject var store: SeveranceStore
    @Environment(\.colorScheme) private var scheme
    @StateObject private var loginItem = LoginItem()

    private var p: Palette { Palette(scheme: scheme) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.waffleParty { waffleBanner }
            gauges
            sectionHeader
            projectList
            footer
        }
        .frame(width: 372)
        .background(
            LinearGradient(colors: [p.panelTop, p.panel], startPoint: .top, endPoint: .bottom)
        )
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            (Text("Seve").fontWeight(.light) + Text("rance").fontWeight(.medium).foregroundColor(p.accent))
                .font(.serifNumerals(15, weight: .light))
                .tracking(3)
                .textCase(.uppercase)
                .foregroundStyle(p.ink)
            Spacer()
            signalBadge
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
    }

    private var signalBadge: some View {
        HStack(spacing: 4) {
            Text("●").foregroundStyle(signalColor).font(.system(size: 8))
            Text(signalText).font(.mono(9.5)).tracking(0.8).textCase(.uppercase)
                .foregroundStyle(p.inkMute)
        }
    }

    private var signalText: String {
        switch store.usage?.signalTier {
        case .statusline: return "statusline · official"
        case .oauth: return "oauth · fallback"
        case .ccusage: return "ccusage · estimate"
        case nil: return "no signal"
        }
    }

    private var signalColor: Color {
        switch store.usage?.signalTier {
        case .statusline: return p.ok
        case .oauth, .ccusage: return p.amber
        case nil: return p.inkMute
        }
    }

    // MARK: gauges

    private var gauges: some View {
        HStack(spacing: 10) {
            GaugeBinView(palette: p, label: "5h Refinement Quota",
                         util: store.usage?.normalized.session.utilization,
                         resetsAt: store.usage?.normalized.session.resetsAtDate,
                         weekly: false, warnThreshold: 70)
            GaugeBinView(palette: p, label: "7d Refinement Quota",
                         util: store.usage?.normalized.weekly.utilization,
                         resetsAt: store.usage?.normalized.weekly.resetsAtDate,
                         weekly: true, warnThreshold: 85)
        }
        .padding(.horizontal, 14).padding(.bottom, 14)
    }

    // MARK: projects

    private var sectionHeader: some View {
        HStack {
            Text("Refiners").font(.system(size: 9.5, weight: .semibold)).tracking(2.4).textCase(.uppercase)
            Spacer()
            Text("\(store.projects.count) tracked").font(.mono(9.5)).opacity(0.7)
        }
        .foregroundStyle(p.inkMute)
        .padding(.horizontal, 16).padding(.top, 9).padding(.bottom, 6)
    }

    @ViewBuilder private var projectList: some View {
        if store.projects.isEmpty {
            Text("No refiners tracked yet. Enable Severance in a project with SEVERANCE_ENABLED=1.")
                .font(.mono(10)).foregroundStyle(p.inkMute)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.bottom, 10)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(store.projects.enumerated()), id: \.element.id) { idx, project in
                    if idx > 0 { Divider().overlay(p.hairline) }
                    ProjectRowView(palette: p, project: project)
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 8)
        }
    }

    // MARK: banner + footer

    private var waffleBanner: some View {
        HStack(spacing: 10) {
            Text("🧇").font(.system(size: 20))
            VStack(alignment: .leading, spacing: 1) {
                Text("Waffle party").font(.serifNumerals(13, weight: .medium)).foregroundStyle(p.mint)
                Text("7d quota → 0% · music dance experience optional")
                    .font(.mono(9.5)).foregroundStyle(p.inkMute)
            }
            Spacer()
            Button(action: { store.waffleParty = false }) {
                Text("✕").foregroundStyle(p.inkMute)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(p.mint.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(p.mint.opacity(0.45), lineWidth: 1))
        .padding(.horizontal, 14).padding(.bottom, 10)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            HStack {
                Toggle("Launch at login", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.set($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.mono(10))
                .foregroundStyle(p.inkSoft)
                Spacer()
                Button("Refresh") { store.refresh() }
                    .buttonStyle(.plain).font(.mono(10)).foregroundStyle(p.inkMute)
                Text("·").foregroundStyle(p.inkMute)
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain).font(.mono(10)).foregroundStyle(p.inkMute)
            }
            HStack {
                Text("~/.claude/severance")
                Spacer()
                Text("please enjoy each window equally")
            }
            .font(.mono(9.5)).foregroundStyle(p.inkMute).opacity(0.85)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .overlay(Divider().overlay(p.hairline), alignment: .top)
    }
}
