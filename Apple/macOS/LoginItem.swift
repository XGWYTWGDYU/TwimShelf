import AppKit
import ServiceManagement
import SwiftUI

/// 开机自启: TwimShelf opens in the background when the person logs in (a login item of its own,
/// SMAppService), and stays running when its window is closed — downloads, sync and tagging go on.
/// No menu bar item: while the window is closed it leaves the Dock too, and opening TwimShelf again
/// (Finder, Launchpad, Spotlight) brings the window back. The login item itself is the setting.
enum LoginItem {
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }
    /// Asked for, but macOS waits for the person to allow it (System Settings › Login Items).
    static var waitingForApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    /// Whether this launch is the login's (read while the app finishes launching).
    static func launchedByLogin() -> Bool {
        guard let e = NSAppleEventManager.shared().currentAppleEvent, e.eventID == AEEventID(kAEOpenApplication) else { return false }
        return e.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }
}

/// The switch in 设置, and its note.
struct LoginItemRow: View {
    @EnvironmentObject private var env: PaneEnv
    @State private var on = LoginItem.isOn || LoginItem.waitingForApproval
    @State private var waiting = LoginItem.waitingForApproval

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ToggleRow(symbol: "power", color: .green, title: L("settings.launchAtLogin"),
                      detail: waiting ? L("settings.launchAtLogin.approve") : L("settings.launchAtLogin.footer"),
                      isOn: Binding(get: { on }, set: { want in
                          do { try LoginItem.set(want) } catch { macAlert(env.window, L("common.notDone"), error.localizedDescription) }
                          refresh()
                          // macOS may want the person's say first: its own page, where they allow it
                          if want, waiting { SMAppService.openSystemSettingsLoginItems() }
                      }))
                .accessibilityIdentifier("launchAtLogin")
            if waiting {
                HStack {
                    Spacer()
                    Button(L("settings.launchAtLogin.openSettings")) { SMAppService.openSystemSettingsLoginItems() }
                }
            }
        }
        .onAppear { refresh() }
        // back from System Settings: what was allowed shows
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        waiting = LoginItem.waitingForApproval
        on = LoginItem.isOn || waiting
    }
}
