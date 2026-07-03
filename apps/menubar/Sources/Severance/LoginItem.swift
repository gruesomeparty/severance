import Foundation
import ServiceManagement

// "Launch at login" via SMAppService (macOS 13+). macOS does not prompt on its
// own — the user flips the toggle, which registers/unregisters the login item.
// Registration is most reliable when the app lives in /Applications and is at
// least ad-hoc signed; failures are swallowed and reflected by re-reading status.
@MainActor
final class LoginItem: ObservableObject {
    @Published var isEnabled: Bool = false

    init() { refresh() }

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func set(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // e.g. unsigned/ad-hoc app outside /Applications, or pending approval.
        }
        refresh()
    }
}
