import AppKit
import InputMethodKit

final class PrisWubiAppDelegate: NSObject, NSApplicationDelegate {
    private var imkServer: IMKServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let bundleId = Bundle.main.bundleIdentifier ?? "com.priswubi.inputmethod.PrisWubi"
        let connName = (Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String)
            ?? "PrisWubi_Connection"

        // Start InputMethodKit Mach server when running inside an IME bundle
        self.imkServer = IMKServer(name: connName, bundleIdentifier: bundleId)

        // Initialize shared Rust mmap core eagerly (< 1ms) so first keystroke has 0ms cold latency
        _ = WubiBridge.shared

        // Allow launching standalone settings UI via `--settings`
        if CommandLine.arguments.contains("--settings") {
            SettingsWindowController.shared.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        WubiBridge.shared.flushUserDataIfNeeded()
    }
}

let app = NSApplication.shared
let delegate = PrisWubiAppDelegate()
app.delegate = delegate
app.run()
