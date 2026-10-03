import AppKit
import Foundation
import Photos
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
    private let folder = FolderLibraryService()
    private let auth = AuthStore()
    private let port = PhotoStreamConstants.defaultPort
    private var pin: String = "----"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Folder photo indexes are ephemeral — always start empty and rescan.
        folder.clearIndex()
        setupStatusItem()
        Task { await startServer() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Drop folder index on shutdown so nothing folder-related lingers on disk/memory.
        folder.clearIndex()
        server?.stop()
        bonjour?.stop()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let icon = NSImage(named: "AppIcon") ?? loadBundledIcon() {
                icon.isTemplate = false
                icon.size = NSSize(width: 18, height: 18)
                button.image = icon
                button.imagePosition = .imageOnly
            } else {
                button.title = "PS"
            }
            button.toolTip = "PhotoStream Server"
        }
        statusItem = item
        rebuildMenu()
    }

    private func loadBundledIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else { return nil }
        return NSImage(contentsOf: url)
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "PhotoStream · port \(port)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "PIN: \(pin)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Folder PIN: \(pin)9", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        let copy = NSMenuItem(title: "Copy PIN", action: #selector(copyPIN), keyEquivalent: "c")
        copy.target = self
        menu.addItem(copy)

        let rotate = NSMenuItem(title: "Rotate PIN", action: #selector(rotatePIN), keyEquivalent: "r")
        rotate.target = self
        menu.addItem(rotate)

        menu.addItem(.separator())

        let folderTitle: String
        if let root = folder.rootURL {
            folderTitle = "Folder: \(root.path)"
        } else {
            folderTitle = "Folder: (none)"
        }
        let folderItem = NSMenuItem(title: folderTitle, action: nil, keyEquivalent: "")
        folderItem.isEnabled = false
        menu.addItem(folderItem)

        let choose = NSMenuItem(title: "Choose Folder…", action: #selector(chooseFolder), keyEquivalent: "f")
        choose.target = self
        menu.addItem(choose)

        let clearFolder = NSMenuItem(title: "Clear Folder", action: #selector(clearFolder), keyEquivalent: "")
        clearFolder.target = self
        clearFolder.isEnabled = folder.isConfigured
        menu.addItem(clearFolder)

        let reload = NSMenuItem(title: "Reload Sources", action: #selector(reloadSources), keyEquivalent: "")
        reload.target = self
        menu.addItem(reload)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem?.menu = menu
    }

    private func startServer() async {
        // Bring the accessory app forward so the Photos TCC sheet can appear.
        // Ad-hoc re-signs change the CDHash, so macOS often asks again every rebuild.
        NSApp.activate(ignoringOtherApps: true)

        pin = await auth.currentPIN()
        rebuildMenu()
        Self.writePINFile(pin)

        let host = Host.current().localizedName ?? "Mac"
        let router = AppRouter(
            library: library,
            folder: folder,
            auth: auth,
            hostName: host,
            port: port
        )
        let http = HTTPServer(port: port) { request in
            await router.handle(request)
        }
        do {
            try http.start()
            server = http
            let advertiser = BonjourAdvertiser(name: host, port: Int(port))
            advertiser.start()
            bonjour = advertiser
            print("PhotoStream listening on \(port), PIN=\(pin) (folder \(pin)9)")
        } catch {
            showAlert(title: "Server failed", message: error.localizedDescription)
            return
        }

        // Load libraries after the port is open so a hung Photos prompt can't
        // block pairing / remote access entirely.
        await loadLibraries()
    }

    private func loadLibraries() async {
        let statusBefore = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        Self.appendLog("photos status before auth: \(statusBefore.rawValue)")
        let authorized = await library.requestAuthorization(timeoutSeconds: 20)
        let statusAfter = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        Self.appendLog(
            "photos authorized=\(authorized) statusAfter=\(statusAfter.rawValue)"
        )
        let hasFolder = folder.isConfigured

        // Always attempt a Photos fetch. On some macOS builds, ad-hoc apps show
        // Photos toggled on in Settings while authorizationStatus stays `.notDetermined`;
        // the fetch still succeeds once TCC has the CDHash.
        library.reload()
        if hasFolder {
            await folder.reload()
        }
        rebuildMenu()
        Self.appendLog(
            "sources ready: photos=\(library.count), folder=\(folder.count) authorized=\(authorized)"
        )
        print(
            "PhotoStream sources ready: photos=\(library.count), folder=\(folder.count)"
        )

        if library.count == 0 && !hasFolder {
            showAlert(
                title: "Photos Access Required",
                message: "Grant Photos access in System Settings → Privacy & Security → Photos (enable PhotoStream), or choose a folder from the menu bar. After a server rebuild you may need to toggle PhotoStream off/on."
            )
        }
    }

    private static func appendLog(_ line: String) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PhotoStream", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("server.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "\(stamp) \(line)\n"
        if let data = text.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
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

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose"
        panel.message = "Photos in this folder (recursive) stream when the iPhone enters PIN + 9."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder.setFolder(url)
        Task { @MainActor in
            await folder.reload()
            rebuildMenu()
            print("Folder set: \(url.path) → \(folder.count) images")
        }
    }

    @objc private func clearFolder() {
        folder.setFolder(nil)
        rebuildMenu()
        print("Folder cleared")
    }

    private static func writePINFile(_ pin: String) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PhotoStream", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("pin.txt")
        try? pin.data(using: .utf8)?.write(to: url)
    }

    @objc private func reloadSources() {
        Task { @MainActor in
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if status == .authorized || status == .limited {
                library.reload()
            }
            if folder.isConfigured {
                folder.clearIndex()
                await folder.reload()
            }
            rebuildMenu()
            print("Reloaded: photos=\(library.count) folder=\(folder.count)")
        }
    }

    @objc private func quitApp() {
        folder.clearIndex()
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
