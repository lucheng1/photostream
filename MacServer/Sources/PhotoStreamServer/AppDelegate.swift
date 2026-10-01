import AppKit
import Foundation
import PhotoStreamShared

@main
enum PhotoStreamMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var server: HTTPServer?
    private var bonjour: BonjourAdvertiser?
    private let library = PhotoLibraryService()
    private let auth = AuthStore()
    private let port = PhotoStreamConstants.defaultPort
    private var pin: String = "----"

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        Task { await startServer() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        bonjour?.stop()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.title = "PS"
            button.toolTip = "PhotoStream Server"
        }
        statusItem = item
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "PhotoStream · port \(port)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "PIN: \(pin)", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        let copy = NSMenuItem(title: "Copy PIN", action: #selector(copyPIN), keyEquivalent: "c")
        copy.target = self
        menu.addItem(copy)

        let rotate = NSMenuItem(title: "Rotate PIN", action: #selector(rotatePIN), keyEquivalent: "r")
        rotate.target = self
        menu.addItem(rotate)

        let reload = NSMenuItem(title: "Reload Library", action: #selector(reloadLibrary), keyEquivalent: "")
        reload.target = self
        menu.addItem(reload)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem?.menu = menu
    }

    private func startServer() async {
        let authorized = await library.requestAuthorization()
        guard authorized else {
            pin = "DENIED"
            rebuildMenu()
            showAlert(
                title: "Photos Access Required",
                message: "Grant Photos access in System Settings → Privacy & Security → Photos, then reopen PhotoStream."
            )
            return
        }

        library.reload()
        pin = await auth.currentPIN()
        rebuildMenu()
        Self.writePINFile(pin)

        let host = Host.current().localizedName ?? "Mac"
        let library = self.library
        let auth = self.auth
        let port = self.port
        let router = AppRouter(library: library, auth: auth, hostName: host, port: port)
        let http = HTTPServer(port: port) { request in
            await router.handle(request)
        }
        do {
            try http.start()
            server = http
            let advertiser = BonjourAdvertiser(name: host, port: Int(port))
            advertiser.start()
            bonjour = advertiser
            print("PhotoStream listening on \(port), assets=\(library.count), PIN=\(pin)")
        } catch {
            showAlert(title: "Server failed", message: error.localizedDescription)
        }
    }

    @objc private func copyPIN() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pin, forType: .string)
    }

    @objc private func rotatePIN() {
        Task { @MainActor in
            pin = await auth.rotatePIN()
            Self.writePINFile(pin)
            rebuildMenu()
        }
    }

    private static func writePINFile(_ pin: String) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PhotoStream", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("pin.txt")
        try? pin.data(using: .utf8)?.write(to: url)
    }

    @objc private func reloadLibrary() {
        library.reload()
        print("Reloaded library: \(library.count) assets")
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
