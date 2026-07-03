import SeveranceCore
import SwiftUI
import UserNotifications

@main
struct SeveranceApp: App {
    @StateObject private var store = SeveranceStore()

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(store)
        } label: {
            MenuBarLabel(store: store)
                .onAppear {
                    store.start()
                    setupWaffleNotifications()
                }
        }
        .menuBarExtraStyle(.window)
    }

    // 🧇 on the 7d reset (§7.7). Guarded so a bare (unbundled) binary can't crash
    // on UNUserNotificationCenter, and opt-out via defaults write.
    private func setupWaffleNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let defaults = UserDefaults.standard
        guard (defaults.object(forKey: "severance.waffleNotifications") as? Bool) ?? true else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        store.onWaffleParty = {
            let content = UNMutableNotificationContent()
            content.title = "Waffle party"
            content.body = "Weekly quota refreshed. All refiners may return to the floor."
            let req = UNNotificationRequest(
                identifier: "severance.waffle.\(UUID().uuidString)", content: content, trigger: nil
            )
            UNUserNotificationCenter.current().add(req)
        }
    }
}

// Compact menu-bar reading: "◦ 5h 62%", "◦ 5h ♪" during the 5-minute music dance
// experience, or "◦ severance" before the first signal.
struct MenuBarLabel: View {
    @ObservedObject var store: SeveranceStore

    private let warn = 75.0
    private let crit = 85.0

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text(text)
        }
        .foregroundStyle(tint)
    }

    private var util: Double? { store.usage?.normalized.session.utilization }

    // Split-circle glyph (the "sever"); a note during the music dance experience.
    private var symbol: String {
        store.musicDanceExperience ? "music.note" : "circle.lefthalf.filled"
    }

    private var text: String {
        if store.musicDanceExperience { return "5h" }
        guard let u = util else { return "severance" }
        return "5h \(Int(u.rounded()))%"
    }

    private var tint: Color {
        guard let u = util else { return .primary }
        if u >= crit { return Color(hex: 0xE06055) }
        if u >= warn { return Color(hex: 0xE8B34B) }
        return .primary
    }
}
