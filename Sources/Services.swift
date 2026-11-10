import AppKit
import CoreGraphics
import Darwin
import Foundation
import SystemConfiguration

struct AirTarget: Equatable {
    var name: String
    var model: String
    var manufacturer: String

    var kind: Kind {
        let model = model.lowercased()
        let name = name.lowercased()
        if model.hasPrefix("appletv") || name.contains("apple tv") { return .appleTV }
        if model.hasPrefix("mac") || name.contains("macbook") || name.contains("imac") || name.contains("mac mini") || name.contains("mac studio") {
            return .mac
        }
        return .tv
    }

    enum Kind { case appleTV, tv, mac }

    var symbol: String {
        switch kind {
        case .appleTV: return "appletv"
        case .tv: return "tv"
        case .mac: return "macbook"
        }
    }
}

struct NearbyMachine: Equatable {
    var name: String
    var model: String
    var flags: UInt32

    var kind: Kind {
        let model = model.lowercased()
        let name = name.lowercased()
        if model.hasPrefix("appletv") { return .appleTV }
        if name.contains("ipad") { return .ipad }
        if name.contains("iphone") { return .iphone }
        if flags & 0x20000 != 0 || name.contains("mac") { return .mac }
        if flags & 0x10000 != 0 { return .ipad }
        return .mac
    }

    var isUniversalControlPeer: Bool {
        switch kind {
        case .mac, .ipad: return true
        case .iphone, .appleTV: return false
        }
    }

    enum Kind { case mac, ipad, iphone, appleTV }

    var symbol: String {
        switch kind {
        case .mac: return "macbook"
        case .ipad: return "ipad"
        case .iphone: return "iphone"
        case .appleTV: return "appletv"
        }
    }
}

enum MachineNames {
    static let computer: String = {
        SCDynamicStoreCopyComputerName(nil, nil) as String? ?? Host.current().localizedName ?? ""
    }()

    static let localHost: String = {
        SCDynamicStoreCopyLocalHostName(nil) as String? ?? ""
    }()

    static func isSelf(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if n.isEmpty { return false }
        return n == computer.lowercased() || n == localHost.lowercased()
    }
}

final class ServiceBrowser {
    struct Record {
        var name: String
        var fields: [String: String] = [:]
    }

    var onUpdate: (([Record]) -> Void)?
    private var counts: [String: Int] = [:]
    private var records: [String: Record] = [:]
    private var browse: Process?
    private var browseSource: DispatchSourceRead?
    private var browseBuffer = ""
    private var resolvers: [String: Process] = [:]
    private var resolveSources: [String: DispatchSourceRead] = [:]
    private let type: String
    private let queue = DispatchQueue(label: "arrange.browse")

    init(type: String) {
        self.type = type
    }

    func start() {
        guard browse == nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
        process.arguments = ["-B", type, "local."]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        // FileHandle.readabilityHandler + availableData goes deaf on 27.2.1: the first
        // callback can be empty, and clearing the handler drops every later browse line.
        let fd = pipe.fileHandleForReading.fileDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { return }
            self.ingest(String(bytes: buffer[..<n], encoding: .utf8) ?? "")
        }
        source.resume()
        browseSource = source
        do {
            try process.run()
            browse = process
        } catch {
            fputs("dns-sd browse failed: \(error)\n", stderr)
        }
    }

    func stop() {
        browseSource?.cancel()
        browseSource = nil
        browse?.terminate()
        browse = nil
        for source in resolveSources.values { source.cancel() }
        resolveSources.removeAll()
        for process in resolvers.values { process.terminate() }
        resolvers.removeAll()
    }

    private func ingest(_ chunk: String) {
        browseBuffer.append(chunk)
        while let newline = browseBuffer.firstIndex(of: "\n") {
            let line = String(browseBuffer[..<newline])
            browseBuffer.removeSubrange(...newline)
            handle(line)
        }
    }

    private func handle(_ line: String) {
        guard let parsed = Self.parseBrowse(line) else { return }
        guard parsed.type.hasPrefix(type) else { return }
        let name = parsed.name
        if parsed.add {
            counts[name, default: 0] += 1
            if records[name] == nil {
                records[name] = Record(name: name)
                resolve(name)
            }
        } else {
            counts[name, default: 1] -= 1
            if (counts[name] ?? 0) <= 0 {
                counts[name] = nil
                records[name] = nil
                resolvers[name]?.terminate()
                resolvers[name] = nil
            }
        }
        publish()
    }

    private func resolve(_ name: String) {
        guard resolvers[name] == nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
        process.arguments = ["-L", name, type, "local."]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        let fd = pipe.fileHandleForReading.fileDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let n = read(fd, &buffer, buffer.count)
            guard n > 0, let text = String(bytes: buffer[..<n], encoding: .utf8) else { return }
            let fields = Self.fields(in: text)
            guard !fields.isEmpty else { return }
            if var record = self.records[name] {
                record.fields.merge(fields) { _, new in new }
                self.records[name] = record
                self.publish()
            }
            self.resolvers[name]?.terminate()
            self.resolvers[name] = nil
            self.resolveSources[name]?.cancel()
            self.resolveSources[name] = nil
        }
        source.resume()
        resolveSources[name] = source
        do {
            try process.run()
            resolvers[name] = process
        } catch {
            return
        }
    }

    private func publish() {
        let snapshot = records.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(snapshot) }
    }

    static func parseBrowse(_ line: String) -> (add: Bool, type: String, name: String)? {
        // dns-sd pads a single-digit hour with a leading space (" 7:24:38"). Before 10:00
        // every browse line was skipped, so a morning launch showed no iPad.
        let line = line.trimmingCharacters(in: .whitespaces)
        let pattern = #"^\S+\s+(Add|Rmv)\s+\d+\s+\d+\s+\S+\s+(\S+)\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let action = Range(match.range(at: 1), in: line),
              let type = Range(match.range(at: 2), in: line),
              let name = Range(match.range(at: 3), in: line) else { return nil }
        return (line[action] == "Add", String(line[type]), String(line[name]).trimmingCharacters(in: .whitespaces))
    }

    static func fields(in text: String) -> [String: String] {
        var found: [String: String] = [:]
        let pattern = #"([A-Za-z0-9]+)=([^\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return found }
        for line in text.split(separator: "\n") {
            let s = String(line)
            let range = NSRange(s.startIndex..., in: s)
            for match in regex.matches(in: s, range: range) {
                guard let k = Range(match.range(at: 1), in: s), let v = Range(match.range(at: 2), in: s) else { continue }
                found[String(s[k])] = String(s[v])
            }
        }
        return found
    }
}

enum SidecarLink {
    static func connect(named name: String, _ done: @escaping (String?) -> Void) {
        guard let manager = manager(),
              let devices = manager.value(forKey: "devices") as? [NSObject],
              let device = devices.first(where: { same($0.value(forKey: "name") as? String, name) }) else {
            done("no sidecar device")
            return
        }
        call(manager, "connectToDevice:completion:", device, done)
    }

    static func disconnect(_ done: @escaping (String?) -> Void) {
        guard let manager = manager(),
              let devices = manager.value(forKey: "connectedDevices") as? [NSObject],
              let device = devices.first else {
            done("not connected")
            return
        }
        call(manager, "disconnectFromDevice:completion:", device, done)
    }

    private static func manager() -> NSObject? {
        _ = dlopen("/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore", RTLD_NOW)
        guard let cls = NSClassFromString("SidecarDisplayManager") as? NSObject.Type else { return nil }
        return cls.perform(NSSelectorFromString("sharedManager"))?.takeUnretainedValue() as? NSObject
    }

    private static func same(_ raw: String?, _ wanted: String) -> Bool {
        func fold(_ text: String) -> String {
            String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
        }
        guard let raw else { return false }
        let left = fold(raw)
        let right = fold(wanted)
        return left == right || left.contains(right) || right.contains(left)
    }

    private static func call(_ manager: NSObject, _ name: String, _ device: NSObject, _ done: @escaping (String?) -> Void) {
        let handler: @convention(block) (NSError?) -> Void = { error in
            DispatchQueue.main.async { done(error.map { "\($0.domain) \($0.code)" }) }
        }
        let sel = NSSelectorFromString(name)
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Void
        let imp = unsafeBitCast(class_getMethodImplementation(type(of: manager), sel), to: Fn.self)
        imp(manager, sel, device, unsafeBitCast(handler, to: AnyObject.self))
    }
}

enum ArrangementHold {
    private static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/dispctl/arrangement-hold")
    }

    static func touch() {
        // Optional: a desk-pin watcher (dispctl) reads this to pause while you arrange. No folder, no-op.
        let dir = url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        } else {
            FileManager.default.createFile(atPath: url.path, contents: Data("arrange\n".utf8))
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

enum DisplayCatalog {
    static func current() -> [LayoutDisplay] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return [] }
        let screens = NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, NSScreen)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (number.uint32Value, screen)
        }
        let total = Int(clamping: count)
        return (0..<total).map { index in
            let id = ids[index]
            let bounds = CGDisplayBounds(id)
            let mirror = CGDisplayMirrorsDisplay(id)
            let screen = screens.first { $0.0 == id }?.1
            return LayoutDisplay(
                id: id,
                name: screen?.localizedName ?? "Display \(id)",
                origin: bounds.origin,
                size: bounds.size,
                isMain: CGDisplayIsMain(id) != 0,
                isBuiltin: CGDisplayIsBuiltin(id) != 0,
                mirrorOf: mirror == 0 ? nil : mirror
            )
        }
    }

    static func wallpaper(for id: CGDirectDisplayID) -> NSImage? {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  number.uint32Value == id,
                  let url = NSWorkspace.shared.desktopImageURL(for: screen) else { continue }
            return NSImage(contentsOf: url)
        }
        return nil
    }

    static func apply(_ displays: [LayoutDisplay]) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        let physical = displays.filter { !$0.isVirtual }
        guard !physical.isEmpty else {
            CGCancelDisplayConfiguration(config)
            return true
        }
        for display in physical {
            if CGConfigureDisplayMirrorOfDisplay(config, display.id, 0) != .success {
                CGCancelDisplayConfiguration(config)
                return false
            }
        }
        for display in physical where display.mirrorOf == nil {
            let x = Int32(display.origin.x.rounded())
            let y = Int32(display.origin.y.rounded())
            if CGConfigureDisplayOrigin(config, display.id, x, y) != .success {
                CGCancelDisplayConfiguration(config)
                return false
            }
        }
        for display in physical {
            guard let master = display.mirrorOf else { continue }
            if CGConfigureDisplayMirrorOfDisplay(config, display.id, master) != .success {
                CGCancelDisplayConfiguration(config)
                return false
            }
        }
        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }
}

enum UniversalControl {
    private static let loaded: Bool = {
        dlopen("/System/Library/PrivateFrameworks/UniversalControl.framework/Versions/A/UniversalControl", RTLD_NOW) != nil
    }()

    private static func preferences() -> NSObject? {
        _ = loaded
        guard let cls = NSClassFromString("UVCPreferences") as? NSObject.Type else { return nil }
        return cls.perform(NSSelectorFromString("sharedPreferences"))?.takeUnretainedValue() as? NSObject
    }

    static var isSupported: Bool { flag("isSupported") }

    static var enabled: Bool {
        get { flag("enabled") }
        set { preferences()?.setValue(newValue, forKey: "enabled") }
    }

    static var pushesThroughEdge: Bool {
        get { flag("magicEdgesEnabled") }
        set { preferences()?.setValue(newValue, forKey: "magicEdgesEnabled") }
    }

    private static func flag(_ key: String) -> Bool {
        guard let raw = preferences()?.value(forKey: key) else { return false }
        if let on = raw as? Bool { return on }
        return (raw as? NSNumber)?.boolValue ?? false
    }

    static func activeEdgeDescriptions(_ done: @escaping ([String]) -> Void) {
        _ = loaded
        let connection = NSXPCConnection(machServiceName: "com.apple.ensemble", options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: EnsembleBasicInterface.self)
        connection.resume()
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            DispatchQueue.main.async {
                connection.invalidate()
                done([])
            }
        }
        guard let basic = proxy as? EnsembleBasicInterface else {
            connection.invalidate()
            done([])
            return
        }
        basic.xpcGetEdgesWithCompletion { edges, _ in
            let lines = (edges as? [Any])?.map { String(describing: $0) } ?? []
            DispatchQueue.main.async {
                connection.invalidate()
                done(lines)
            }
        }
    }

    static func linkedTiles(named name: String, among displays: [LayoutDisplay]) -> [LayoutDisplay] {
        guard enabled, let manager = managerPointer() else { return [] }
        ensureSynced(manager)
        let label = name.isEmpty ? "iPad" : name
        let size = UCArranger.peerSize ?? CGSize(width: 1210, height: 834)
        var tiles: [LayoutDisplay] = []
        for (index, edge) in linkEdgeRects(manager).prefix(1).enumerated() {
            guard let host = displays.first(where: { !$0.isVirtual && $0.mirrorOf == nil && touches($0.frame, edge) }) else { continue }
            guard let origin = tileOrigin(edge: edge, host: host, size: size) else { continue }
            tiles.append(LayoutDisplay(
                id: 0xE1000001 + UInt32(index),
                name: label,
                origin: origin,
                size: size,
                isMain: false,
                isBuiltin: false,
                mirrorOf: nil,
                isVirtual: true
            ))
        }
        return tiles
    }

    private static var didSync = false

    private static func ensureSynced(_ manager: UnsafeRawPointer) {
        guard !didSync, let syncedFn, let waitFn else { return }
        if !ucCallBool(manager, syncedFn) {
            let mode = Unmanaged.passUnretained(RunLoop.Mode.default.rawValue as NSString).toOpaque()
            ucCallWait(manager, waitFn, mode, 0.4)
        }
        didSync = ucCallBool(manager, syncedFn)
    }

    static func hasActiveLink() -> Bool {
        guard enabled, let manager = managerPointer() else { return false }
        ensureSynced(manager)
        return !linkEdgeRects(manager).isEmpty
    }

    private static func edgeRects(_ manager: UnsafeRawPointer) -> [CGRect] {
        guard let edgesFn, let rectFn else { return [] }
        return ucCallArray(manager, edgesFn).map { edge in
            ucCallRect(Unmanaged.passUnretained(edge).toOpaque(), rectFn)
        }
    }

    /// Idle Universal Control publishes push-to-connect zones on opposite outer sides of the
    /// desktop (seen 2026-11-04: x=2963 and x=-1920, both full desk height). A connected iPad
    /// on one display is a single outer edge the same size as that display (2026-11-10: left
    /// edge (0,0,1,840) while Displays showed the iPad beside the built-in screen).
    private static func linkEdgeRects(_ manager: UnsafeRawPointer) -> [CGRect] {
        let edges = edgeRects(manager)
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success, count > 0 else { return edges }
        let frames = (0..<Int(count)).map { CGDisplayBounds(ids[$0]) }
        let desk = frames.reduce(CGRect.null) { $0.union($1) }
        func spansDesk(_ e: CGRect) -> Bool {
            let fullHeight = e.width <= 1.5 && e.height >= desk.height - 2
                && (abs(e.minX - desk.minX) < 2 || abs(e.maxX - desk.maxX) < 2)
            let fullWidth = e.height <= 1.5 && e.width >= desk.width - 2
                && (abs(e.minY - desk.minY) < 2 || abs(e.maxY - desk.maxY) < 2)
            return fullHeight || fullWidth
        }
        let partial = edges.filter { !spansDesk($0) }
        if !partial.isEmpty { return partial }
        let spanning = edges.filter(spansDesk)
        // One outer edge is the peer. Two or more are the idle push zones.
        return spanning.count == 1 ? spanning : []
    }

    private static func touches(_ frame: CGRect, _ edge: CGRect) -> Bool {
        frame.insetBy(dx: -2, dy: -2).intersects(edge)
    }

    private static func tileOrigin(edge: CGRect, host: LayoutDisplay, size: CGSize) -> CGPoint? {
        let frame = host.frame
        let vertical = edge.height > edge.width
        if vertical && abs(edge.minX - frame.minX) < 3 {
            return CGPoint(x: frame.minX - size.width, y: along(edge.minY, edge.maxY, frame.minY, frame.maxY, size.height))
        }
        if vertical && abs(edge.maxX - frame.maxX) < 3 {
            return CGPoint(x: frame.maxX, y: along(edge.minY, edge.maxY, frame.minY, frame.maxY, size.height))
        }
        if !vertical && abs(edge.minY - frame.minY) < 3 {
            return CGPoint(x: along(edge.minX, edge.maxX, frame.minX, frame.maxX, size.width), y: frame.minY - size.height)
        }
        if !vertical && abs(edge.maxY - frame.maxY) < 3 {
            return CGPoint(x: along(edge.minX, edge.maxX, frame.minX, frame.maxX, size.width), y: frame.maxY)
        }
        return nil
    }

    /// The edge is the overlap. An end inside the host is the iPad's real end; otherwise centre it.
    private static func along(_ e0: CGFloat, _ e1: CGFloat, _ h0: CGFloat, _ h1: CGFloat, _ length: CGFloat) -> CGFloat {
        if e0 > h0 + 3 && e1 >= h1 - 3 { return e0 }
        if e1 < h1 - 3 && e0 <= h0 + 3 { return e1 - length }
        return (e0 + e1) / 2 - length / 2
    }

    private static func managerPointer() -> UnsafeRawPointer? {
        guard let sharedFn, let cls = NSClassFromString("UniversalControl.UniversalControlManager") else { return nil }
        let meta = unsafeBitCast(cls, to: UnsafeRawPointer.self)
        let pointer = ucCallPtr(meta, sharedFn)
        return UInt(bitPattern: pointer) > 0x1000 ? pointer : nil
    }

    private static func symbol(_ name: String) -> UnsafeRawPointer? {
        _ = loaded
        guard let handle = dlopen("/System/Library/PrivateFrameworks/UniversalControl.framework/Versions/A/UniversalControl", RTLD_NOW) else { return nil }
        return dlsym(handle, name).map(UnsafeRawPointer.init)
    }

    private static let sharedFn = symbol("$s16UniversalControl0aB7ManagerC6sharedACvgZ")
    private static let syncedFn = symbol("$s16UniversalControl0aB7ManagerC14isSynchronizedSbvgTj")
    private static let waitFn = symbol("$s16UniversalControl0aB7ManagerC21waitUntilSynchronized2in11forIntervalySo13NSRunLoopModea_SdtF")
    private static let edgesFn = symbol("$s16UniversalControl0aB7ManagerC11activeEdgesSayAA0aB10EdgeRegionCGvgTj")
    private static let rectFn = symbol("$s16UniversalControl0aB10EdgeRegionC4rectSo6CGRectVvgTj")
}

@objc protocol EnsembleBasicInterface {
    func xpcGetEdgesWithCompletion(_ completion: @escaping (NSArray?, NSError?) -> Void)
}

@_silgen_name("uc_ptr")
func ucCallPtr(_ object: UnsafeRawPointer, _ fn: UnsafeRawPointer) -> UnsafeRawPointer
@_silgen_name("uc_arr")
func ucCallArray(_ object: UnsafeRawPointer, _ fn: UnsafeRawPointer) -> [AnyObject]
@_silgen_name("uc_rect")
func ucCallRect(_ object: UnsafeRawPointer, _ fn: UnsafeRawPointer) -> CGRect
@_silgen_name("uc_bool")
func ucCallBool(_ object: UnsafeRawPointer, _ fn: UnsafeRawPointer) -> Bool
@_silgen_name("uc_wait")
func ucCallWait(_ object: UnsafeRawPointer, _ fn: UnsafeRawPointer, _ mode: UnsafeRawPointer, _ seconds: Double)
@_silgen_name("uc_arm")
func ucArm(_ manager: UnsafeRawPointer, _ fn: UnsafeRawPointer)
@_silgen_name("uc_assert_dev")
func ucAssertDev(_ name: String) -> UnsafeRawPointer
@_silgen_name("uc_set_true")
func ucSetTrue(_ manager: UnsafeRawPointer, _ fn: UnsafeRawPointer)
