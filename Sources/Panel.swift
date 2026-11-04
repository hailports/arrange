import AppKit

/// Display-only relabel for screenshots: ARRANGE_LABELS="Real Name=Shown Name|Other=Shown".
/// Matching, linking and arranging always use the real names.
private let labelMap: [String: String] = {
    let raw = ProcessInfo.processInfo.environment["ARRANGE_LABELS"] ?? ""
    var map: [String: String] = [:]
    for pair in raw.split(separator: "|") {
        let parts = pair.split(separator: "=", maxSplits: 1).map { String($0) }
        if parts.count == 2 { map[UCArranger.fold(parts[0])] = parts[1] }
    }
    return map
}()

func shownName(_ name: String) -> String { labelMap[UCArranger.fold(name)] ?? name }

final class ArrangeCanvas: NSView {
    var displays: [LayoutDisplay] = [] { didSet { needsDisplay = true } }
    var wallpapers: [UInt32: NSImage] = [:] { didSet { needsDisplay = true } }
    var onCommit: (([LayoutDisplay]) -> Void)?

    private(set) var isDragging = false
    private var dragID: UInt32?
    private var dragMode = DragMode.move
    private var grabOffset = CGPoint.zero
    private var dragVector = CGVector.zero
    private var preview: [LayoutDisplay] = []
    private var dragMap: Map?
    private var hoverMenuBar = false

    private enum DragMode { case move, menuBar }

    private struct Map {
        var scale: CGFloat
        var origin: CGPoint
    }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 328, height: 196) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let background = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        NSColor.quaternarySystemFill.setFill()
        background.fill()

        let items = shown
        guard let map = dragMap ?? mapping(for: items) else { return }
        let mirroredMasters = Set(displays.compactMap(\.mirrorOf))

        for item in items {
            let rect = viewRect(for: item, map: map)
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowBlurRadius = item.id == dragID ? 14 : 7
            shadow.shadowOffset = NSSize(width: 0, height: isFlipped ? 1 : -1)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
            shadow.set()
            NSColor.black.withAlphaComponent(0.2).setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()

            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            if item.isVirtual {
                NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
                rect.fill()
            } else if let image = wallpapers[item.id] {
                image.draw(in: aspectFill(image.size, in: rect), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                NSColor.windowBackgroundColor.setFill()
                rect.fill()
            }
            let scrim = NSGradient(colors: [NSColor.black.withAlphaComponent(0), NSColor.black.withAlphaComponent(0.55)])
            scrim?.draw(in: NSRect(x: rect.minX, y: rect.maxY - 36, width: rect.width, height: 36), angle: isFlipped ? -90 : 90)
            NSGraphicsContext.restoreGraphicsState()

            NSColor.black.withAlphaComponent(0.22).setStroke()
            path.lineWidth = 1
            path.stroke()

            if item.isMain {
                let barRect = menuBarRect(in: rect)
                let bar = NSBezierPath(roundedRect: barRect, xRadius: 2.5, yRadius: 2.5)
                NSColor.white.withAlphaComponent(hoverMenuBar && dragID == nil ? 1 : 0.94).setFill()
                bar.fill()
            }

            if rect.width > 40 {
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byTruncatingTail
                let shadow = NSShadow()
                shadow.shadowBlurRadius = 2
                shadow.shadowOffset = NSSize(width: 0, height: 0)
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
                let title = mirroredMasters.contains(item.id) ? "\(shownName(item.name))  ·  Mirrored" : shownName(item.name)
                let text = NSAttributedString(string: title, attributes: [
                    .font: NSFont.systemFont(ofSize: rect.width > 84 ? 11 : 9, weight: .semibold),
                    .foregroundColor: NSColor.white,
                    .paragraphStyle: style,
                    .shadow: shadow
                ])
                let textRect = NSRect(x: rect.minX + 6, y: rect.maxY - 20, width: max(rect.width - 10, 1), height: 14)
                text.draw(in: textRect)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let items = shown
        guard let map = mapping(for: items) else { return }
        for item in items.reversed() {
            let rect = viewRect(for: item, map: map)
            guard rect.contains(point) else { continue }
            dragID = item.id
            dragMap = map
            isDragging = true
            let displayPoint = toDisplay(point, map: map)
            grabOffset = CGPoint(x: displayPoint.x - item.origin.x, y: displayPoint.y - item.origin.y)
            dragVector = .zero
            dragMode = !item.isVirtual && item.isMain && menuBarRect(in: rect).contains(point) ? .menuBar : .move
            preview = displays
            NSCursor.closedHand.push()
            needsDisplay = true
            return
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragID, let map = dragMap, var moving = displays.first(where: { $0.id == dragID }) else { return }
        let point = convert(event.locationInWindow, from: nil)
        let displayPoint = toDisplay(point, map: map)
        if dragMode == .menuBar {
            var next = displays
            if let under = item(at: point, map: map, in: next.filter { $0.mirrorOf == nil && !$0.isVirtual }) {
                next = LayoutMath.moveMenuBar(to: under.id, displays: displays)
            }
            preview = next
        } else if !moving.isVirtual && event.modifierFlags.contains(.option),
                  let host = item(at: point, map: map, in: shown.filter { $0.id != dragID && !$0.isVirtual }),
                  host.id != dragID {
            var next = displays
            if let index = next.firstIndex(where: { $0.id == dragID }) {
                next[index].mirrorOf = host.id
                next[index].isMain = false
            }
            preview = next
        } else {
            let proposed = CGPoint(x: displayPoint.x - grabOffset.x, y: displayPoint.y - grabOffset.y)
            dragVector = CGVector(dx: proposed.x - moving.origin.x, dy: proposed.y - moving.origin.y)
            let others = displays.filter { $0.id != dragID && $0.mirrorOf == nil }
            moving.mirrorOf = nil
            moving.origin = LayoutMath.place(moving, proposed: proposed, among: others, drag: dragVector, settle: false)
            moving.isMain = displays.first { $0.id == dragID }?.isMain ?? false
            let next = displays.map { item -> LayoutDisplay in
                if item.id == dragID { return moving }
                if item.mirrorOf == dragID { return item }
                return item
            }
            preview = next
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        var next = preview.isEmpty ? displays : preview
        if dragMode == .move, let dragID, let index = next.firstIndex(where: { $0.id == dragID }) {
            let moving = next[index]
            let others = next.filter { $0.id != dragID && $0.mirrorOf == nil }
            var settled = moving
            settled.mirrorOf = nil
            settled.origin = LayoutMath.place(moving, proposed: moving.origin, among: others, drag: dragVector, settle: true)
            next[index] = settled
        }
        NSCursor.pop()
        onCommit?(next)
        dragID = nil
        dragMap = nil
        preview = []
        isDragging = false
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isDragging, let map = mapping(for: shown), let main = shown.first(where: \.isMain) else { return }
        let point = convert(event.locationInWindow, from: nil)
        let hot = menuBarRect(in: viewRect(for: main, map: map)).contains(point)
        if hot != hoverMenuBar {
            hoverMenuBar = hot
            needsDisplay = true
        }
        if hot { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
    }

    private var shown: [LayoutDisplay] {
        let source = preview.isEmpty ? displays : preview
        return source.filter { $0.mirrorOf == nil }
    }

    private func mapping(for items: [LayoutDisplay]) -> Map? {
        guard let first = items.first else { return nil }
        var union = first.frame
        for item in items.dropFirst() { union = union.union(item.frame) }
        let inset = bounds.insetBy(dx: 10, dy: 10)
        guard union.width > 1, union.height > 1, inset.width > 1, inset.height > 1 else { return nil }
        let scale = min(inset.width / union.width, inset.height / union.height)
        let used = CGSize(width: union.width * scale, height: union.height * scale)
        let origin = CGPoint(
            x: inset.minX + (inset.width - used.width) / 2 - union.minX * scale,
            y: inset.minY + (inset.height - used.height) / 2 - union.minY * scale
        )
        return Map(scale: scale, origin: origin)
    }

    private func viewRect(for item: LayoutDisplay, map: Map) -> NSRect {
        NSRect(
            x: map.origin.x + item.origin.x * map.scale,
            y: map.origin.y + item.origin.y * map.scale,
            width: max(item.size.width * map.scale, 1),
            height: max(item.size.height * map.scale, 1)
        )
    }

    private func toDisplay(_ point: NSPoint, map: Map) -> CGPoint {
        CGPoint(x: (point.x - map.origin.x) / map.scale, y: (point.y - map.origin.y) / map.scale)
    }

    private func menuBarRect(in rect: NSRect) -> NSRect {
        NSRect(x: rect.minX + 5, y: rect.minY + 5, width: max(rect.width - 10, 1), height: min(11, rect.height * 0.09))
    }

    private func item(at point: NSPoint, map: Map, in items: [LayoutDisplay]) -> LayoutDisplay? {
        items.reversed().first { viewRect(for: $0, map: map).contains(point) }
    }

    private func aspectFill(_ image: CGSize, in rect: NSRect) -> NSRect {
        guard image.width > 0, image.height > 0 else { return rect }
        let scale = max(rect.width / image.width, rect.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return NSRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

final class DeviceRow: NSView {
    var onClick: (() -> Void)?
    var symbol = "tv" { didSet { applySymbol() } }
    var filled = false { didSet { applySymbol() } }
    var showsSwitch = false
    var switchOn = false
    var onSwitch: ((Bool) -> Void)?

    private let iconWell = NSView()
    private let icon = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private var toggle: NSSwitch?
    private var hovered = false

    override var intrinsicContentSize: NSSize { NSSize(width: 352, height: 40) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(title: String, detail: String? = nil) {
        super.init(frame: NSRect(x: 0, y: 0, width: 352, height: 40))
        wantsLayer = true
        iconWell.wantsLayer = true
        icon.imageScaling = .scaleProportionallyDown
        titleField.stringValue = title
        titleField.font = .systemFont(ofSize: 13)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingTail
        detailField.stringValue = detail ?? ""
        detailField.font = .systemFont(ofSize: 11)
        detailField.textColor = .secondaryLabelColor
        detailField.isHidden = detail == nil
        addSubview(iconWell)
        iconWell.addSubview(icon)
        addSubview(titleField)
        addSubview(detailField)
    }

    required init?(coder: NSCoder) { nil }

    func installSwitch() {
        showsSwitch = true
        let control = NSSwitch()
        control.controlSize = .small
        control.state = switchOn ? .on : .off
        control.target = self
        control.action = #selector(switched(_:))
        toggle = control
        addSubview(control)
    }

    override func layout() {
        super.layout()
        let well = NSRect(x: 12, y: (bounds.height - 28) / 2, width: 28, height: 28)
        iconWell.frame = well
        iconWell.layer?.cornerRadius = 14
        icon.frame = NSRect(x: 6, y: 6, width: 16, height: 16)
        let trailing: CGFloat = showsSwitch ? 58 : 16
        let textX: CGFloat = 48
        let textW = max(bounds.width - textX - trailing, 20)
        if detailField.isHidden {
            titleField.frame = NSRect(x: textX, y: (bounds.height - 18) / 2, width: textW, height: 18)
        } else {
            titleField.frame = NSRect(x: textX, y: bounds.midY - 1, width: textW, height: 16)
            detailField.frame = NSRect(x: textX, y: bounds.midY - 16, width: textW, height: 14)
        }
        if let toggle {
            let size = toggle.intrinsicContentSize
            toggle.frame = NSRect(x: bounds.width - size.width - 14, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        }
        applySymbol()
        layer?.cornerRadius = 8
        layer?.backgroundColor = hovered ? NSColor.quaternaryLabelColor.withAlphaComponent(0.18).cgColor : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsLayout = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsLayout = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        if let toggle, toggle.frame.contains(point) { return }
        onClick?()
    }

    @objc private func switched(_ sender: NSSwitch) {
        onSwitch?(sender.state == .on)
    }

    private func applySymbol() {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        icon.contentTintColor = filled ? .white : .labelColor
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let idle = dark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.06)
        iconWell.layer?.backgroundColor = (filled ? NSColor.controlAccentColor : idle).cgColor
    }
}

final class MirrorPanelController: NSObject {
    private let window: NSPanel
    private let chrome: NSView
    private let stack = NSStackView()
    private let canvas = ArrangeCanvas()
    private var statusItem: NSStatusItem?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let airBrowser = ServiceBrowser(type: "_airplay._tcp")
    private let nearbyBrowser = ServiceBrowser(type: "_companion-link._tcp")
    private var airRecords: [ServiceBrowser.Record] = []
    private var nearbyRecords: [ServiceBrowser.Record] = []
    private var displays: [LayoutDisplay] = []
    private var wallpapers: [UInt32: NSImage] = [:]
    private var virtualPlacements: [UInt32: CGPoint] = [:]
    private var pendingSidecarOrigin: CGPoint?
    private var edgeNotes: [String] = []
    private var showAllAirPlay = false
    private var placed = false
    /// Companion-link presence is not a UC link. Only the row the user armed, while edges stay live.
    /// Persisted so a restart keeps the blue row; cleared when every UC edge goes away.
    private var armedUniversalControlName: String? {
        get { UserDefaults.standard.string(forKey: "ucArmedPeer") }
        set { UserDefaults.standard.set(newValue, forKey: "ucArmedPeer") }
    }

    override init() {
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 352, height: 480),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        var usesGlassContent = false
        if let glassType = NSClassFromString("NSGlassEffectView") as? NSView.Type {
            let glass = glassType.init(frame: NSRect(x: 0, y: 0, width: 352, height: 480))
            glass.setValue(22.0, forKey: "cornerRadius")
            glass.setValue(true, forKey: "clipsToBounds")
            chrome = glass
            usesGlassContent = glass.responds(to: Selector(("setContentView:")))
        } else {
            let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 352, height: 480))
            effect.material = .popover
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 16
            effect.layer?.masksToBounds = true
            chrome = effect
        }
        super.init()
        window.isFloatingPanel = true
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false
        window.contentView = chrome
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.userInterfaceLayoutDirection = .leftToRight
        stack.translatesAutoresizingMaskIntoConstraints = false
        if usesGlassContent {
            chrome.setValue(stack, forKey: "contentView")
        } else {
            chrome.addSubview(stack)
        }
        let host = stack.superview ?? chrome
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            stack.topAnchor.constraint(equalTo: host.topAnchor),
            stack.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 352)
        ])
        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.heightAnchor.constraint(equalToConstant: 196).isActive = true
        canvas.onCommit = { [weak self] next in self?.commit(next) }

        airBrowser.onUpdate = { [weak self] records in
            self?.airRecords = records
            self?.rebuild()
        }
        nearbyBrowser.onUpdate = { [weak self] records in
            self?.nearbyRecords = records
            self?.reloadDisplays()
        }
    }

    private static func statusImage() -> NSImage {
        let size = NSSize(width: 20, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
                NSRect(x: x, y: y, width: w, height: h)
            }
            func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            }
            let stroke: CGFloat = 1.35
            let bezelRect = box(0.75, 4.05, 12.7, 9.35)
            NSGraphicsContext.saveGraphicsState()
            let clip = NSBezierPath(rect: box(0, 0, size.width, size.height))
            clip.append(rounded(bezelRect, 1.7))
            clip.windingRule = .evenOdd
            clip.addClip()
            NSColor.black.setStroke()
            let square = rounded(box(8.55, 6.85, 9.5, 8.15), 1.85)
            square.lineWidth = stroke
            square.lineJoinStyle = .round
            square.stroke()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.black.setStroke()
            let bezel = rounded(bezelRect, 1.7)
            bezel.lineWidth = stroke
            bezel.lineJoinStyle = .round
            bezel.stroke()
            let midX = bezelRect.midX
            let neck = NSBezierPath()
            neck.lineWidth = stroke
            neck.lineCapStyle = .round
            neck.move(to: NSPoint(x: midX, y: bezelRect.minY - stroke * 0.15))
            neck.line(to: NSPoint(x: midX, y: 2.1))
            neck.stroke()
            let foot = NSBezierPath()
            foot.lineWidth = stroke
            foot.lineCapStyle = .round
            foot.move(to: NSPoint(x: midX - 2.7, y: 2.1))
            foot.line(to: NSPoint(x: midX + 2.7, y: 2.1))
            foot.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Displays"
        return image
    }

    private var holdTimer: Timer?

    func install() {
        ArrangementHold.touch()
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            ArrangementHold.touch()
        }
        let image = Self.statusImage()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = image
        item.button?.toolTip = "Displays"
        item.button?.target = self
        item.button?.action = #selector(statusClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        reloadDisplays()
        airBrowser.start()
        nearbyBrowser.start()
        CGDisplayRegisterReconfigurationCallback({ _, flags, user in
            guard let user else { return }
            if flags.contains(.beginConfigurationFlag) { return }
            let controller = Unmanaged<MirrorPanelController>.fromOpaque(user).takeUnretainedValue()
            DispatchQueue.main.async { controller.reloadDisplays() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func shutdown() {
        holdTimer?.invalidate()
        holdTimer = nil
        ArrangementHold.clear()
        airBrowser.stop()
        nearbyBrowser.stop()
    }

    func show() {
        reloadDisplays()
        refreshEdges()
        rebuild()
        window.makeKeyAndOrderFront(nil)
        place()
        installMonitors()
        DispatchQueue.main.async { [weak self] in self?.place() }
    }

    @objc private func statusClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Quit Arrange", action: #selector(quit), keyEquivalent: "q")
            menu.items.forEach { $0.target = self }
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
            return
        }
        if window.isVisible {
            close()
        } else {
            show()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func close() {
        window.orderOut(nil)
        removeMonitors()
    }

    private func installMonitors() {
        removeMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.window.isVisible else { return }
            let point = NSEvent.mouseLocation
            if self.window.frame.contains(point) { return }
            if let icon = self.statusItem?.button?.window?.frame, icon.contains(point) { return }
            self.close()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 {
                self?.close()
                return nil
            }
            return event
        }
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func place() {
        window.layoutIfNeeded()
        stack.layoutSubtreeIfNeeded()
        let width: CGFloat = 352
        let height = min(max(stack.fittingSize.height, 200), 920)
        let icon = statusItem?.button?.window?.frame ?? .zero
        let screen = (icon.width > 2 ? NSScreen.screens.first { $0.frame.intersects(icon) } : nil) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        var originX = visible.maxX - width - 12
        var originY = visible.maxY - height
        if icon.width > 2, icon.height > 2 {
            originX = icon.midX - width / 2
            originY = icon.minY - height - 6
        }
        originX = min(max(originX, visible.minX + 8), visible.maxX - width - 8)
        originY = min(max(originY, visible.minY + 8), visible.maxY - min(height, visible.height - 8))
        window.setFrame(NSRect(x: originX, y: originY, width: width, height: height), display: true)
        placed = true
    }

    private func reloadDisplays() {
        guard !canvas.isDragging else { return }
        refreshArrangement()
        if window.isVisible { rebuild() }
    }

    private func refreshArrangement() {
        var next = DisplayCatalog.current()
        let linked = UniversalControl.hasActiveLink()
        if !linked {
            virtualPlacements.removeAll()
            armedUniversalControlName = nil
        }
        let ipad = nearbyMachines.first { $0.kind == .ipad }?.name ?? "iPad"
        let sidecarOn = next.contains { $0.name.localizedCaseInsensitiveContains("sidecar") }
        if !sidecarOn && linked {
            var tiles = UniversalControl.linkedTiles(named: ipad, among: next)
            for index in tiles.indices {
                if let origin = virtualPlacements[tiles[index].id] {
                    tiles[index].origin = origin
                }
            }
            next.append(contentsOf: tiles)
        }
        displays = next
        for display in displays where !display.isVirtual && wallpapers[display.id] == nil {
            wallpapers[display.id] = DisplayCatalog.wallpaper(for: display.id)
        }
        canvas.displays = displays
        canvas.wallpapers = wallpapers
        placeSidecarIfNeeded()
    }

    private func placeSidecarIfNeeded() {
        guard let origin = pendingSidecarOrigin,
              displays.contains(where: { $0.name.localizedCaseInsensitiveContains("sidecar") }) else { return }
        pendingSidecarOrigin = nil
        var next = displays.filter { !$0.isVirtual }
        guard let index = next.firstIndex(where: { $0.name.localizedCaseInsensitiveContains("sidecar") }) else { return }
        next[index].origin = origin
        guard DisplayCatalog.apply(next) else { return }
        refreshArrangement()
    }

    private func refreshEdges() {
        UniversalControl.activeEdgeDescriptions { [weak self] notes in
            self?.edgeNotes = notes
            if self?.window.isVisible == true { self?.rebuild() }
        }
    }

    private func commit(_ next: [LayoutDisplay]) {
        var arranged = next
        if let main = arranged.first(where: { $0.isMain && $0.mirrorOf == nil }) {
            arranged = LayoutMath.moveMenuBar(to: main.id, displays: arranged)
        }
        let previous = displays
        let live = DisplayCatalog.current()
        let physical = arranged.filter { !$0.isVirtual }
        if !LayoutMath.sameArrangement(live, physical) {
            _ = DisplayCatalog.apply(physical)
        }
        let moved = arranged.first { item in
            item.isVirtual && previous.first(where: { $0.id == item.id })?.origin != item.origin
        }
        if let moved { NSLog("Arrange: virtual drop %@ target=%@", NSStringFromRect(moved.frame), UCArranger.target(for: moved.frame, among: physical, peer: moved.name).map { "\($0.side) \($0.along)" } ?? "none") }
        if let moved, var target = UCArranger.target(for: moved.frame, among: physical, peer: moved.name),
           let before = previous.first(where: { $0.id == moved.id })?.origin {
            target.delta = CGVector(dx: moved.origin.x - before.x, dy: moved.origin.y - before.y)
            applyUniversalControl(target, tile: moved, physical: physical)
            return
        }
        refreshArrangement()
        rebuild()
    }

    /// Connect or disconnect through the Displays "+" menu, the same switch System Settings uses.
    private var togglingUC = false
    private func toggleUniversalControl(_ name: String) {
        guard !togglingUC else { return }
        guard UCArranger.trusted else {
            UCArranger.promptForTrust()
            return
        }
        togglingUC = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = UCArranger.linkMenu(toggle: name)
            DispatchQueue.main.async {
                guard let self else { return }
                self.togglingUC = false
                NSLog("Arrange: UC toggle %@: %@", name, result.note)
                if let peers = result.peers {
                    self.universalControlPeers = Array(peers.keys)
                    self.armedUniversalControlName = peers.first { $0.value }?.key
                }
                if result.note != "connected" && result.note != "disconnected" { NSSound.beep() }
                self.reloadDisplays()
                self.refreshEdges()
            }
        }
    }

    /// Real UC peers as System Settings lists them; nil until the menu has been read once.
    private var universalControlPeers: [String]? {
        get { UserDefaults.standard.stringArray(forKey: "ucMenuPeers") }
        set { UserDefaults.standard.set(newValue, forKey: "ucMenuPeers") }
    }

    /// Real UC edge move: drive the System Settings Arrange sheet, then re-read the daemon edge.
    private var arrangingUC = false
    private func applyUniversalControl(_ target: UCArranger.Target, tile: LayoutDisplay, physical: [LayoutDisplay]) {
        guard !arrangingUC else { return }
        guard UCArranger.trusted else {
            UCArranger.promptForTrust()
            edgeNotes = ["Allow Arrange in Accessibility to move the iPad"]
            refreshArrangement()
            rebuild()
            return
        }
        arrangingUC = true
        virtualPlacements[tile.id] = tile.origin
        close()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = UCArranger.apply(target, displays: physical)
            DispatchQueue.main.async {
                guard let self else { return }
                self.arrangingUC = false
                // The tile must reflect the live edge, never a preview.
                self.virtualPlacements.removeValue(forKey: tile.id)
                if let seen = UCArranger.lastSheetPeer { self.armedUniversalControlName = seen }
                if !outcome.ok {
                    NSLog("Arrange: UC arrange failed: %@", outcome.note)
                    NSSound.beep()
                }
                self.show()
                self.refreshArrangement()
                self.rebuild()
                self.refreshEdges()
            }
        }
    }

    private var airTargets: [AirTarget] {
        airRecords.compactMap { record in
            guard !MachineNames.isSelf(record.name) else { return nil }
            return AirTarget(name: record.name, model: record.fields["model"] ?? "", manufacturer: record.fields["manufacturer"] ?? "")
        }.sorted { lhs, rhs in
            let left = lhs.kind == .mac ? 1 : 0
            let right = rhs.kind == .mac ? 1 : 0
            if left != right { return left < right }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var nearbyMachines: [NearbyMachine] {
        nearbyRecords.compactMap { record -> NearbyMachine? in
            guard !MachineNames.isSelf(record.name) else { return nil }
            let flags = UInt32(record.fields["rpFl"]?.replacingOccurrences(of: "0x", with: "").uppercased() ?? "0", radix: 16) ?? 0
            let machine = NearbyMachine(name: record.name, model: record.fields["rpMd"] ?? "", flags: flags)
            return machine.isUniversalControlPeer ? machine : nil
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func rebuild() {
        guard !canvas.isDragging else { return }
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        stack.addArrangedSubview(labelBlock("Displays", size: 15, weight: .semibold, color: .labelColor, top: 14, bottom: 10))
        stack.addArrangedSubview(rule())
        stack.addArrangedSubview(labelBlock("Arrange Displays", size: 13, weight: .semibold, color: .labelColor, top: 12, bottom: 2))
        stack.addArrangedSubview(labelBlock("Drag to arrange. Option-drag one onto another to mirror. Drag the white bar to move the menu bar.", size: 11, weight: .regular, color: .secondaryLabelColor, top: 0, bottom: 8, wrap: true))
        let canvasPad = NSView()
        canvasPad.translatesAutoresizingMaskIntoConstraints = false
        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvasPad.addSubview(canvas)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: canvasPad.leadingAnchor, constant: 12),
            canvas.trailingAnchor.constraint(equalTo: canvasPad.trailingAnchor, constant: -12),
            canvas.topAnchor.constraint(equalTo: canvasPad.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: canvasPad.bottomAnchor, constant: -10),
            canvas.heightAnchor.constraint(equalToConstant: 196)
        ])
        stack.addArrangedSubview(canvasPad)
        if displays.contains(where: { $0.mirrorOf != nil }) {
            stack.addArrangedSubview(actionRow("Stop Mirroring", action: #selector(stopMirroring)))
        }

        stack.addArrangedSubview(rule())
        stack.addArrangedSubview(labelBlock("Mirroring", size: 13, weight: .regular, color: .secondaryLabelColor, top: 10, bottom: 4))
        let sidecars = displays.filter { !$0.isVirtual && $0.name.localizedCaseInsensitiveContains("sidecar") }
        if sidecars.isEmpty {
            for machine in nearbyMachines where machine.kind == .ipad {
                let row = DeviceRow(title: shownName(machine.name))
                row.symbol = "ipad"
                row.onClick = { [weak self] in
                    SidecarLink.connect(named: machine.name) { [weak self] _ in self?.reloadDisplays() }
                }
                stack.addArrangedSubview(row)
            }
        } else {
            for display in sidecars {
                let row = DeviceRow(title: shownName(display.name))
                row.symbol = "ipad"
                row.filled = true
                row.onClick = { [weak self] in
                    SidecarLink.disconnect { [weak self] _ in self?.reloadDisplays() }
                }
                stack.addArrangedSubview(row)
            }
        }
        let targets = airTargets
        let visible = showAllAirPlay ? targets : Array(targets.prefix(4))
        if sidecars.isEmpty && visible.isEmpty {
            stack.addArrangedSubview(labelBlock("Looking for AirPlay receivers…", size: 12, weight: .regular, color: .tertiaryLabelColor, top: 2, bottom: 8))
        }
        for target in visible {
            let row = DeviceRow(title: shownName(target.name))
            row.symbol = target.symbol
            row.onClick = { [weak self] in self?.pick(target) }
            stack.addArrangedSubview(row)
        }
        if targets.count > 4 {
            stack.addArrangedSubview(actionRow(showAllAirPlay ? "Show Less" : "Show More", action: #selector(toggleAirList), chevron: !showAllAirPlay))
        }

        stack.addArrangedSubview(rule())
        stack.addArrangedSubview(labelBlock("Link keyboard and mouse to:", size: 13, weight: .regular, color: .secondaryLabelColor, top: 10, bottom: 4))
        // Once System Settings' link menu has been read, list only the peers it offers.
        let allowed = universalControlPeers.map { Set($0.map(UCArranger.fold)) }
        let machines = nearbyMachines.filter { allowed?.contains(UCArranger.fold($0.name)) ?? true }
        if !UniversalControl.isSupported {
            stack.addArrangedSubview(labelBlock("Universal Control isn’t supported on this Mac.", size: 12, weight: .regular, color: .secondaryLabelColor, top: 2, bottom: 8))
        } else if machines.isEmpty {
            stack.addArrangedSubview(labelBlock("No nearby Macs or iPads", size: 12, weight: .regular, color: .tertiaryLabelColor, top: 2, bottom: 8))
        }
        let linked = UniversalControl.hasActiveLink()
        for machine in machines {
            let row = DeviceRow(title: shownName(machine.name))
            row.symbol = machine.kind == .ipad ? "ipad" : "laptopcomputer"
            // Blue = the Displays link menu showed a check on this peer, and a real link edge is live.
            row.filled = linked && armedUniversalControlName.map { UCArranger.fold($0) == UCArranger.fold(machine.name) } == true
            row.onClick = { [weak self] in
                self?.toggleUniversalControl(machine.name)
            }
            stack.addArrangedSubview(row)
        }

        stack.addArrangedSubview(rule())
        stack.addArrangedSubview(actionRow("Display Settings...", action: #selector(openSettings)))
        stack.addArrangedSubview(spacer(6))

        if window.isVisible { place() }
    }

    private func pick(_ target: AirTarget) {
        // Network AirPlay mirroring is started by Control Center, which holds a private entitlement.
        // The row stays a live receiver, same names and icons as the system menu.
        NSSound.beep()
        _ = target
    }

    @objc private func toggleAirList() {
        showAllAirPlay.toggle()
        rebuild()
    }

    @objc private func toggleUniversal(_ sender: NSSwitch) {
        UniversalControl.enabled = sender.state == .on
        rebuild()
    }

    @objc private func toggleEdge(_ sender: NSSwitch) {
        UniversalControl.pushesThroughEdge = sender.state == .on
    }

    @objc private func stopMirroring() {
        var next = displays
        var occupied = next.filter { $0.mirrorOf == nil && !$0.isVirtual }.map(\.frame)
        for index in next.indices {
            guard let masterID = next[index].mirrorOf,
                  let master = next.first(where: { $0.id == masterID }) else { continue }
            var origin = CGPoint(x: master.frame.maxX, y: master.origin.y)
            var frame = CGRect(origin: origin, size: next[index].size)
            if occupied.contains(where: { $0.insetBy(dx: -1, dy: -1).intersects(frame) }) {
                origin = CGPoint(x: master.origin.x, y: master.frame.maxY)
                frame.origin = origin
            }
            next[index].origin = origin
            next[index].mirrorOf = nil
            next[index].isMain = false
            occupied.append(frame)
        }
        commit(next)
    }

    @objc private func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
        close()
    }

    private func labelBlock(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, top: CGFloat, bottom: CGFloat, wrap: Bool = false) -> NSView {
        let wrapView = NSView()
        let label = wrap ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.alignment = .left
        label.translatesAutoresizingMaskIntoConstraints = false
        if wrap {
            label.preferredMaxLayoutWidth = 320
            label.maximumNumberOfLines = 3
            label.cell?.wraps = true
        }
        wrapView.addSubview(label)
        NSLayoutConstraint.activate([
            wrapView.widthAnchor.constraint(equalToConstant: 352),
            label.leftAnchor.constraint(equalTo: wrapView.leftAnchor, constant: 16),
            label.rightAnchor.constraint(equalTo: wrapView.rightAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: wrapView.topAnchor, constant: top),
            label.bottomAnchor.constraint(equalTo: wrapView.bottomAnchor, constant: -bottom)
        ])
        return wrapView
    }

    private func rule() -> NSView {
        let wrap = NSView()
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(box)
        NSLayoutConstraint.activate([
            wrap.widthAnchor.constraint(equalToConstant: 352),
            box.leftAnchor.constraint(equalTo: wrap.leftAnchor),
            box.rightAnchor.constraint(equalTo: wrap.rightAnchor),
            box.topAnchor.constraint(equalTo: wrap.topAnchor),
            box.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
            box.heightAnchor.constraint(equalToConstant: 1)
        ])
        return wrap
    }

    private func spacer(_ height: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    private func actionRow(_ title: String, action: Selector, chevron: Bool = false) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 352).isActive = true
        row.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.alignment = .left
        button.font = .systemFont(ofSize: 13)
        button.contentTintColor = .labelColor
        button.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            button.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        if chevron {
            let image = NSImageView()
            image.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
            image.contentTintColor = .tertiaryLabelColor
            image.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(image)
            NSLayoutConstraint.activate([
                image.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
                image.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 10),
                image.heightAnchor.constraint(equalToConstant: 14)
            ])
        }
        return row
    }

    private func switchRow(_ title: String, detail: String, on: Bool, action: Selector) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 352).isActive = true
        row.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 13)
        titleField.alignment = .left
        titleField.translatesAutoresizingMaskIntoConstraints = false
        let detailField = NSTextField(labelWithString: detail)
        detailField.font = .systemFont(ofSize: 11)
        detailField.alignment = .left
        detailField.textColor = .secondaryLabelColor
        detailField.translatesAutoresizingMaskIntoConstraints = false
        let toggle = NSSwitch()
        toggle.controlSize = .small
        toggle.state = on ? .on : .off
        toggle.target = self
        toggle.action = action
        toggle.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(titleField)
        row.addSubview(detailField)
        row.addSubview(toggle)
        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -8),
            titleField.topAnchor.constraint(equalTo: row.topAnchor, constant: 6),
            detailField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            detailField.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -8),
            detailField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 0),
            toggle.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            toggle.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }
}
