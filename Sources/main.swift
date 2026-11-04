import AppKit
import Darwin
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    let panel = MirrorPanelController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel.install()
        if ProcessInfo.processInfo.environment["ARRANGE_SHOW"] == "1" {
            DispatchQueue.main.async { self.panel.show() }
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
            let parseOK = parsed?.add == true && parsed?.name == "Example TV" && (parsed?.type.hasPrefix("_airplay._tcp") == true)
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
}
