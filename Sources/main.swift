import AppKit
import Darwin
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    let panel = MirrorPanelController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel.install()
        if ProcessInfo.processInfo.environment["ARRANGE_SHOW"] == "1" {
            DispatchQueue.main.async { self.panel.show() }
        } else {
            ArrangeMain.promptForAccessibilityIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        panel.shutdown()
    }
}

@main
enum ArrangeMain {
    private static let appDelegate = AppDelegate()
    private static var termSource: DispatchSourceSignal?

    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            let layoutOK = LayoutSelfTest.run()
            let sample = "10:52:45.761  Add        3  11 local.               _airplay._tcp.       Example TV"
            let parsed = ServiceBrowser.parseBrowse(sample)
            let morning = ServiceBrowser.parseBrowse(" 7:24:38.331  Add        3  11 local.               _companion-link._tcp. alex's iPad pro")
            let parseOK = parsed?.add == true && parsed?.name == "Example TV" && (parsed?.type.hasPrefix("_airplay._tcp") == true)
                && morning?.add == true && morning?.name == "alex's iPad pro"
            if !parseOK {
                fputs("FAIL parseBrowse got \(String(describing: parsed))\n", stderr)
            }
            exit((layoutOK && parseOK) ? 0 : 1)
        }

        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            appDelegate.panel.shutdown()
            NSApp.terminate(nil)
        }
        source.resume()
        termSource = source

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = appDelegate
        app.run()
    }

    /// One prompt per OS build. An update drops the Accessibility grant; the next login asks again.
    static func promptForAccessibilityIfNeeded() {
        guard !UCArranger.trusted else { return }
        let build = ProcessInfo.processInfo.operatingSystemVersionString
        let key = "axPromptedBuild"
        guard UserDefaults.standard.string(forKey: key) != build else { return }
        UserDefaults.standard.set(build, forKey: key)
        UCArranger.promptForTrust()
    }
}
