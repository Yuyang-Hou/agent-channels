import AppKit
import SwiftUI

#if !SELF_TEST
@MainActor
private final class PijooAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await AppModel.shared.reconcileChannelFeedsAndHistory() }
    }

    @objc private func workspaceDidWake(_ notification: Notification) {
        Task { await AppModel.shared.resumeAfterSystemWake() }
    }

    @objc private func workspaceWillSleep(_ notification: Notification) {
        AppModel.shared.prepareForSystemSleep()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        AppModel.shared.shutdown()
    }
}

@main
private struct PijooV2App: App {
    @NSApplicationDelegateAdaptor(PijooAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("Pijoo", id: "main") {
            MainWindowView(model: model)
                .frame(minWidth: 900, minHeight: 620)
        }
        .defaultSize(width: 1100, height: 760)

        MenuBarExtra {
            V2MenuPanel(model: model)
        } label: {
            BrandIcon(fallback: model.menuIcon, size: 18)
                .accessibilityLabel("Pijoo")
        }
        .menuBarExtraStyle(.window)
    }
}
#endif
