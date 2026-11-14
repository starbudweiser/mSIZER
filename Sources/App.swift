// mSIZER — traitement de photos par lots. Version personnelle et simplifiée d'un logiciel de traitement par lots.
import SwiftUI

@main
struct MsizerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("mSIZER", id: "main") {
            ContentView()
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(L.t("menu.about")) { About.show() }
            }
            CommandGroup(replacing: .newItem) {
                Button(L.t("menu.add")) { if Store.shared.mode == .raw { RawStore.shared.pickFiles() } else { Store.shared.pickFiles() } }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .appSettings) {
                Button(L.t("menu.settings")) { Store.shared.showSettings = true }.keyboardShortcut(",")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Socle.brand("mSIZER", color: Brand.color)
        Socle.apply()
        // Mise à jour : une recherche par jour, installée seulement quand aucun traitement ne tourne.
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            Task { @MainActor in Updater.shared.tick(busy: Store.shared.processing || RawStore.shared.converting) }
        }
        Task { @MainActor in Updater.shared.tick(busy: Store.shared.processing || RawStore.shared.converting) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in Store.route(urls) }
    }
}
