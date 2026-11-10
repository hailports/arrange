import AppKit
import ApplicationServices

/// Moves the real Universal Control edge by driving the System Settings Arrange sheet.
/// That extension holds com.apple.universalcontrol; this app cannot commit itself (-71168).
/// Proven 2026-11-04: a 20 pt drag of the iPad tile moved the live edge y 1080→1391, and back.
enum UCArranger {
    enum Side { case left, right, top, bottom }

    struct Target {
        var host: CGRect      // global CG frame of the display the tile was dropped against
        var side: Side
        var along: CGFloat    // tile centre along that side, 0...1 of the host side
        var peer: String      // iPad name shown in the sheet
        var delta = CGVector.zero  // how far the user moved the tile, global points
    }

    struct Outcome { var ok: Bool; var note: String }

    /// Real peer size in global points, learned from the Arrange sheet.
    static var peerSize: CGSize? {
        get {
            let d = UserDefaults.standard
            let w = d.double(forKey: "ucPeerWidth"), h = d.double(forKey: "ucPeerHeight")
            return w > 100 && h > 100 ? CGSize(width: w, height: h) : nil
        }
        set {
            UserDefaults.standard.set(newValue?.width ?? 0, forKey: "ucPeerWidth")
            UserDefaults.standard.set(newValue?.height ?? 0, forKey: "ucPeerHeight")
        }
    }

    /// Name the Arrange sheet showed for the UC peer: the only source that ties an edge to a device.
    static var lastSheetPeer: String?

    static var trusted: Bool { AXIsProcessTrusted() }

    static func promptForTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Where the dropped virtual tile sits relative to the physical displays.
    static func target(for tile: CGRect, among displays: [LayoutDisplay], peer: String) -> Target? {
        var best: (Target, CGFloat)?
        for display in displays where !display.isVirtual && display.mirrorOf == nil {
            let f = display.frame
            let candidates: [(Side, CGFloat, CGFloat)] = [
                (.right, abs(tile.minX - f.maxX), overlap(tile.minY, tile.maxY, f.minY, f.maxY)),
                (.left, abs(tile.maxX - f.minX), overlap(tile.minY, tile.maxY, f.minY, f.maxY)),
                (.bottom, abs(tile.minY - f.maxY), overlap(tile.minX, tile.maxX, f.minX, f.maxX)),
                (.top, abs(tile.maxY - f.minY), overlap(tile.minX, tile.maxX, f.minX, f.maxX)),
            ]
            for (side, gap, shared) in candidates where gap < 4 && shared > 0 {
                let vertical = side == .left || side == .right
                let along = vertical ? (tile.midY - f.minY) / f.height : (tile.midX - f.minX) / f.width
                let t = Target(host: f, side: side, along: min(max(along, 0), 1), peer: peer)
                if best == nil || shared > best!.1 { best = (t, shared) }
            }
        }
        return best?.0
    }

    /// Settings opened in the background, parked on the main display, hidden under our cover.
    private struct Session {
        let app: NSRunningApplication
        let root: AXUIElement
        let window: AXUIElement
        let frame: CGRect
        let close: () -> Void
    }

    private static let settingsBundle = "com.apple.systempreferences"

    private static func openCovered() -> (Session?, String) {
        let bundle = settingsBundle
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty
        let saved = CGEvent(source: nil)?.location
        let previous = DispatchQueue.main.sync { NSWorkspace.shared.frontmostApplication }
        let close = {
            if let saved { CGWarpMouseCursorPosition(saved) }
            if !wasRunning {
                NSRunningApplication.runningApplications(withBundleIdentifier: bundle).forEach { $0.terminate() }
            }
            DispatchQueue.main.sync {
                Cover.shared.hide()
                if let previous, previous.bundleIdentifier != bundle { previous.activate() }
            }
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") else {
            return (nil, "bad settings url")
        }
        // Background open: Settings never comes forward on its own.
        DispatchQueue.main.sync {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.open(url, configuration: config)
        }
        guard let app = waitFor(4, { NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first }) else {
            close(); return (nil, "System Settings did not open")
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = waitFor(4, { (attr(root, kAXWindowsAttribute) as? [AXUIElement])?.first }) else {
            close(); return (nil, "Settings window did not appear")
        }
        let main = CGDisplayBounds(CGMainDisplayID())
        var spot = CGPoint(x: main.minX + 80, y: main.minY + 40)
        if let value = AXValueCreate(.cgPoint, &spot) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
        let windowFrame = frame(window).insetBy(dx: -24, dy: -24)
        DispatchQueue.main.sync { Cover.shared.show(windowFrame, hole: nil) }
        return (Session(app: app, root: root, window: window, frame: windowFrame, close: close), "")
    }

    /// The Displays "+" menu lists real UC peers with a check on the linked one.
    /// Reads it, optionally presses `toggle` (connects, or disconnects if checked), then re-reads.
    static func linkMenu(toggle name: String?) -> (peers: [String: Bool]?, note: String) {
        guard trusted else { return (nil, "Arrange needs Accessibility") }
        let (opened, error) = openCovered()
        guard let s = opened else { return (nil, error) }
        defer { s.close() }
        func readMenu(press: String?) -> [String: Bool]? {
            guard let plus = waitFor(5, { find(s.root) { (attr($0, kAXIdentifierAttribute) as? String) == "plus" } }) else { return nil }
            AXUIElementPerformAction(plus, kAXPressAction as CFString)
            guard let menu = waitFor(2, { find(s.root) { e in
                role(e) == "AXMenu" && children(e).contains { (attr($0, kAXTitleAttribute) as? String) == "Link keyboard and mouse to" }
            } }) else { return nil }
            var peers: [String: Bool] = [:]
            var inUC = false
            var hit: AXUIElement?
            for item in children(menu) {
                let title = attr(item, kAXTitleAttribute) as? String ?? ""
                if title == "Link keyboard and mouse to" { inUC = true; continue }
                if title == "Mirror or extend to" { inUC = false; continue }
                guard inUC, !title.isEmpty else { continue }
                let mark = attr(item, kAXMenuItemMarkCharAttribute) as? String ?? ""
                peers[title] = !mark.isEmpty
                if let press, fold(title) == fold(press) { hit = item }
            }
            if let hit {
                AXUIElementPerformAction(hit, kAXPressAction as CFString)
            } else {
                AXUIElementPerformAction(menu, kAXCancelAction as CFString)
            }
            return peers
        }
        guard let first = readMenu(press: name) else { return (nil, "link menu not found") }
        guard let name else { return (first, "read") }
        guard first.keys.contains(where: { fold($0) == fold(name) }) else { return (first, "not a Universal Control peer") }
        let wanted = !(first.first { fold($0.key) == fold(name) }?.value ?? false)
        // Linking takes a few seconds; poll the check mark.
        var last = first
        for _ in 0..<8 {
            usleep(800_000)
            guard let now = readMenu(press: nil) else { continue }
            last = now
            if (now.first { fold($0.key) == fold(name) }?.value ?? false) == wanted { return (now, wanted ? "connected" : "disconnected") }
        }
        return (last, "no change")
    }

    /// Blocking; call off the main thread. Opens Settings covered, drags, presses Done, closes Settings.
    static func apply(_ target: Target, displays: [LayoutDisplay]) -> Outcome {
        guard trusted else { return Outcome(ok: false, note: "Arrange needs Accessibility") }
        let (opened, error) = openCovered()
        guard let s = opened else { return Outcome(ok: false, note: error) }
        defer { s.close() }
        let app = s.app, root = s.root, window = s.window, windowFrame = s.frame
        guard let arrange = waitFor(5, { find(root) { desc($0) == "Arrange…" || desc($0) == "Arrange..." } }) else {
            return Outcome(ok: false, note: "Arrange button not found")
        }
        AXUIElementPerformAction(arrange, kAXPressAction as CFString)
        guard let view = waitFor(4, { find(root) { desc($0) == "Arrangement View" } }) else {
            return Outcome(ok: false, note: "Arrange sheet did not open")
        }
        usleep(400_000)
        var result = Outcome(ok: false, note: "iPad not in Arrange sheet")
        repeat {
            guard let sheet = readSheet(view, peer: target.peer, displays: displays) else { break }
            guard let hostTile = sheet.hostTile(for: target.host) else {
                result = Outcome(ok: false, note: "host display not matched in sheet")
                break
            }
            if sheet.mapX.a > 0.001, sheet.mapY.a > 0.001 {
                peerSize = CGSize(width: sheet.peer.width / sheet.mapX.a, height: sheet.peer.height / sheet.mapY.a)
            }
            // Replay the user's move in sheet scale. The canvas tile came from the live edge, so the
            // delta is the intent; the sheet does its own snapping. Host choice only matters for logging.
            let from = CGPoint(x: sheet.peer.midX, y: sheet.peer.midY)
            let inner = sheet.bounds.insetBy(dx: 4, dy: 4)
            let want = CGPoint(x: min(max(from.x + target.delta.dx * sheet.mapX.a, inner.minX), inner.maxX),
                               y: min(max(from.y + target.delta.dy * sheet.mapY.a, inner.minY), inner.maxY))
            NSLog("Arrange: UC move delta=%@ peer=%@ hostTile=%@ want=%@",
                  NSStringFromSize(NSSize(width: target.delta.dx, height: target.delta.dy)), NSStringFromRect(sheet.peer), NSStringFromRect(hostTile), NSStringFromPoint(want))
            if hypot(want.x - from.x, want.y - from.y) < 1.5 {
                result = Outcome(ok: true, note: "no move needed")
                break
            }
            // The sheet drops events under any window above the hit point, so open a hole over the drag path only.
            let path = sheet.peer.union(sheet.peer.offsetBy(dx: want.x - from.x, dy: want.y - from.y)).insetBy(dx: -8, dy: -8)
            DispatchQueue.main.sync { Cover.shared.show(windowFrame, hole: path) }
            app.activate()   // first click on a background window only activates it
            _ = waitFor(1.5, { app.isActive ? true : nil })
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            usleep(250_000)
            drag(from: from, to: want)
            usleep(500_000)
            // The sheet recentres and snaps after a drop: success = the peer moved relative to its host.
            if let after = readSheet(view, peer: target.peer, displays: displays), let h2 = after.hostTile(for: target.host) {
                let before = CGPoint(x: sheet.peer.midX - hostTile.midX, y: sheet.peer.midY - hostTile.midY)
                let now = CGPoint(x: after.peer.midX - h2.midX, y: after.peer.midY - h2.midY)
                let moved = hypot(now.x - before.x, now.y - before.y) > 2
                result = moved ? Outcome(ok: true, note: "placed") : Outcome(ok: false, note: "drag did not land")
            }
        } while false
        NSLog("Arrange: UC arrange outcome ok=%d %@", result.ok ? 1 : 0, result.note)
        if let done = find(root, { desc($0) == "Done" }) {
            AXUIElementPerformAction(done, kAXPressAction as CFString)
            usleep(800_000)
        }
        return result
    }

    // MARK: cover

    /// Click-through windows over the Settings window, leaving only the drag path open.
    final class Cover {
        static let shared = Cover()
        private var windows: [NSWindow] = []

        func show(_ frame: CGRect, hole: CGRect?) {
            hide()
            let primary = NSScreen.screens.first?.frame.height ?? 0
            func flip(_ r: CGRect) -> NSRect { NSRect(x: r.minX, y: primary - r.maxY, width: r.width, height: r.height) }
            var parts = [frame]
            if let hole = hole?.intersection(frame), !hole.isNull {
                parts = [
                    CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: hole.minY - frame.minY),
                    CGRect(x: frame.minX, y: hole.maxY, width: frame.width, height: frame.maxY - hole.maxY),
                    CGRect(x: frame.minX, y: hole.minY, width: hole.minX - frame.minX, height: hole.height),
                    CGRect(x: hole.maxX, y: hole.minY, width: frame.maxX - hole.maxX, height: hole.height),
                ].filter { $0.width > 0 && $0.height > 0 }
            }
            let largest = parts.max { $0.width * $0.height < $1.width * $1.height }
            for part in parts {
                let window = NSWindow(contentRect: flip(part), styleMask: .borderless, backing: .buffered, defer: false)
                window.level = .screenSaver
                window.ignoresMouseEvents = true
                window.hasShadow = false
                window.isOpaque = false
                window.backgroundColor = .clear
                window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
                let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: part.size))
                effect.material = .hudWindow
                effect.blendingMode = .behindWindow
                effect.state = .active
                window.contentView = effect
                if part == largest {
                    let label = NSTextField(labelWithString: "Moving iPad…")
                    label.font = .systemFont(ofSize: 15, weight: .medium)
                    label.textColor = .secondaryLabelColor
                    label.alignment = .center
                    label.frame = NSRect(x: 0, y: part.height / 2 - 11, width: part.width, height: 22)
                    effect.addSubview(label)
                }
                window.orderFrontRegardless()
                windows.append(window)
            }
        }

        func hide() {
            windows.forEach { $0.orderOut(nil) }
            windows.removeAll()
        }
    }

    // MARK: sheet geometry

    private struct Sheet {
        var bounds: CGRect
        var peer: CGRect
        var tiles: [CGRect]                 // display tiles in sheet coords
        var mapX: (a: CGFloat, b: CGFloat)  // sheet = a * global + b
        var mapY: (a: CGFloat, b: CGFloat)

        func hostTile(for host: CGRect) -> CGRect? {
            let predicted = CGPoint(x: mapX.a * host.midX + mapX.b, y: mapY.a * host.midY + mapY.b)
            return tiles.min { hypot($0.midX - predicted.x, $0.midY - predicted.y) < hypot($1.midX - predicted.x, $1.midY - predicted.y) }
        }
    }

    private static func readSheet(_ view: AXUIElement, peer name: String, displays: [LayoutDisplay]) -> Sheet? {
        let images = children(view).filter { role($0) == "AXImage" }
        let folded = fold(name)
        let tiles = images.filter { MachineNames.isSelf(desc($0)) }.map { frame($0) }
        let others = images.filter { !MachineNames.isSelf(desc($0)) }
        // Exact folded name, else the only non-display tile in the sheet.
        let match = others.first { fold(desc($0)) == folded } ?? (others.count == 1 ? others.first : nil)
        let peer = match.map { frame($0) }
        if let match { lastSheetPeer = desc(match) }
        let physical = displays.filter { !$0.isVirtual && $0.mirrorOf == nil }
        guard let peer, !tiles.isEmpty, tiles.count == physical.count else { return nil }
        // Same left-to-right order both sides; fit a linear map per axis.
        let globals = physical.map(\.frame).sorted { ($0.midX, $0.midY) < ($1.midX, $1.midY) }
        let sheets = tiles.sorted { ($0.midX, $0.midY) < ($1.midX, $1.midY) }
        let ax = fit(globals.map(\.midX), sheets.map(\.midX), scale: sheets[0].width / globals[0].width)
        let ay = fit(globals.map(\.midY), sheets.map(\.midY), scale: sheets[0].height / globals[0].height)
        return Sheet(bounds: frame(view), peer: peer, tiles: tiles, mapX: ax, mapY: ay)
    }

    private static func fit(_ x: [CGFloat], _ y: [CGFloat], scale: CGFloat) -> (a: CGFloat, b: CGFloat) {
        let n = CGFloat(x.count)
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        let vx = x.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        let a = vx > 1 ? zip(x, y).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / vx : scale
        return (a, my - a * mx)
    }

    private static func drag(from start: CGPoint, to end: CGPoint) {
        let src = CGEventSource(stateID: .hidSystemState)
        func post(_ type: CGEventType, _ p: CGPoint) {
            CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        post(.mouseMoved, start); usleep(150_000)
        post(.leftMouseDown, start); usleep(150_000)
        for i in 1...20 {
            let f = CGFloat(i) / 20
            post(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * f, y: start.y + (end.y - start.y) * f))
            usleep(25_000)
        }
        usleep(200_000)
        post(.leftMouseUp, end)
    }

    // MARK: AX helpers

    private static func attr(_ e: AXUIElement, _ key: String) -> AnyObject? {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(e, key as CFString, &value)
        return value
    }
    private static func desc(_ e: AXUIElement) -> String { attr(e, kAXDescriptionAttribute) as? String ?? "" }
    private static func role(_ e: AXUIElement) -> String { attr(e, kAXRoleAttribute) as? String ?? "" }
    private static func children(_ e: AXUIElement) -> [AXUIElement] { attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
    private static func frame(_ e: AXUIElement) -> CGRect {
        var origin = CGPoint.zero, size = CGSize.zero
        if let v = attr(e, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &origin) }
        if let v = attr(e, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &size) }
        return CGRect(origin: origin, size: size)
    }
    private static func find(_ e: AXUIElement, depth: Int = 0, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
        if match(e) { return e }
        guard depth < 30 else { return nil }
        for child in children(e) { if let hit = find(child, depth: depth + 1, match) { return hit } }
        return nil
    }
    private static func waitFor<T>(_ seconds: Double, _ probe: () -> T?) -> T? {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            if let hit = probe() { return hit }
            usleep(150_000)
        } while Date() < end
        return nil
    }
    private static func overlap(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> CGFloat {
        max(0, min(a1, b1) - max(a0, b0))
    }
    static func fold(_ s: String) -> String {
        s.replacingOccurrences(of: "’", with: "'").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// "alex's iPad pro" and the older Displays-menu name "alex's iPad pro (2)" are one peer.
    static func samePeer(_ a: String, _ b: String) -> Bool {
        let x = fold(a), y = fold(b)
        return x == y || x.hasPrefix(y) || y.hasPrefix(x)
    }
}
