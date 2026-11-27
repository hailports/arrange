import AppKit
import Foundation

/// Pulls newer builds from hailports/arrange GitHub Releases and replaces this bundle.
/// Silent while the panel is closed; never runs a display apply. MacBook only in practice.
enum ArrangeUpdater {
    static let repo = "hailports/arrange"
    private static let defaultsKey = "arrangeUpdaterLastCheck"
    private static var timer: Timer?
    private static var checking = false

    static func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { check(forced: false) }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            check(forced: false)
        }
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { check(forced: false) }
        }
    }

    static func check(forced: Bool) {
        guard !checking else { return }
        if !forced {
            let last = UserDefaults.standard.double(forKey: defaultsKey)
            if last > 0, Date().timeIntervalSince1970 - last < 3600 { return }
        }
        checking = true
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: defaultsKey)
        let work = {
            defer { DispatchQueue.main.async { checking = false } }
            do {
                try runCheck()
            } catch {
                NSLog("Arrange: update check failed: %@", "\(error)")
            }
        }
        if CommandLine.arguments.contains("--check-update") {
            work()
        } else {
            DispatchQueue.global(qos: .utility).async(execute: work)
        }
    }

    private static func runCheck() throws {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Arrange/\(currentShortVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let sem = DispatchSemaphore(value: 0)
        var data: Data?
        var httpError: Error?
        URLSession.shared.dataTask(with: request) { body, _, error in
            data = body
            httpError = error
            sem.signal()
        }.resume()
        sem.wait()
        if let httpError { throw httpError }
        guard let data,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let tag = ((json["tag_name"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        guard !tag.isEmpty, isNewer(tag, than: currentShortVersion) else { return }
        guard let assets = json["assets"] as? [[String: Any]],
              let asset = assets.first(where: { (($0["name"] as? String) ?? "").hasSuffix(".dmg") }),
              let download = asset["browser_download_url"] as? String,
              let downloadURL = URL(string: download) else {
            throw UpdateError.noDMG
        }
        NSLog("Arrange: updating %@ → %@", currentShortVersion, tag)
        let dmg = try downloadFile(downloadURL, name: (asset["name"] as? String) ?? "Arrange.dmg")
        try install(dmg: dmg)
    }

    private static var currentShortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Loose semver: 1.1.0 > 1.0, 1.2 > 1.1.0
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        let n = max(a.count, b.count)
        for i in 0..<n {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func downloadFile(_ url: URL, name: String) throws -> URL {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        let sem = DispatchSemaphore(value: 0)
        var err: Error?
        let task = URLSession.shared.downloadTask(with: url) { temp, _, error in
            defer { sem.signal() }
            if let error { err = error; return }
            guard let temp else { err = UpdateError.download; return }
            do {
                try FileManager.default.moveItem(at: temp, to: dest)
            } catch {
                err = error
            }
        }
        task.resume()
        sem.wait()
        if let err { throw err }
        return dest
    }

    private static func install(dmg: URL) throws {
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("arrange-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        defer {
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", mount.path, "-quiet"]
            try? detach.run(); detach.waitUntilExit()
            try? FileManager.default.removeItem(at: dmg)
        }
        let attach = Process()
        attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        attach.arguments = ["attach", dmg.path, "-nobrowse", "-quiet", "-mountpoint", mount.path]
        try attach.run()
        attach.waitUntilExit()
        guard attach.terminationStatus == 0 else { throw UpdateError.mount }
        let src = mount.appendingPathComponent("Arrange.app")
        guard FileManager.default.fileExists(atPath: src.path) else { throw UpdateError.noAppInDMG }
        let dest = installedAppURL()
        let staging = dest.deletingLastPathComponent().appendingPathComponent("Arrange.updating.app")
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.copyItem(at: src, to: staging)
        // Prefer keeping the local signing identity so Accessibility survives.
        resignIfPossible(staging)
        let backup = dest.deletingLastPathComponent().appendingPathComponent("Arrange.prev.app")
        try? FileManager.default.removeItem(at: backup)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.moveItem(at: dest, to: backup)
        }
        try FileManager.default.moveItem(at: staging, to: dest)
        try? FileManager.default.removeItem(at: backup)
        relaunch(dest)
    }

    private static func installedAppURL() -> URL {
        let homeApps = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Arrange.app")
        let homeDir = homeApps.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
        // Always land updates in ~/Applications so LaunchAgent + ship agree.
        // Dev builds under Developer/ still migrate there on first update.
        return homeApps
    }

    private static func resignIfPossible(_ app: URL) {
        let identity = ProcessInfo.processInfo.environment["ARRANGE_SIGN_IDENTITY"]
            ?? "7894BB24D88A0E407BA41F3BE6F65EAFE068DC80"
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--deep", "--sign", identity, app.path]
        sign.standardOutput = Pipe()
        sign.standardError = Pipe()
        do {
            try sign.run()
            sign.waitUntilExit()
            if sign.terminationStatus != 0 {
                let adhoc = Process()
                adhoc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                adhoc.arguments = ["--force", "--deep", "--sign", "-", app.path]
                try adhoc.run()
                adhoc.waitUntilExit()
            }
        } catch {
            NSLog("Arrange: resign skipped: %@", "\(error)")
        }
    }

    private static func relaunch(_ app: URL) {
        let bin = app.appendingPathComponent("Contents/MacOS/Arrange").path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", "sleep 1; open -a \(shellEscape(app.path))"]
        try? task.run()
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
        _ = bin
    }

    private static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    enum UpdateError: Error {
        case noDMG, download, mount, noAppInDMG
    }
}
