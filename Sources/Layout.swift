import Foundation
import CoreGraphics

struct LayoutDisplay: Equatable {
    var id: UInt32
    var name: String
    var origin: CGPoint
    var size: CGSize
    var isMain: Bool
    var isBuiltin: Bool
    var mirrorOf: UInt32?
    var isVirtual: Bool

    init(id: UInt32, name: String, origin: CGPoint, size: CGSize, isMain: Bool, isBuiltin: Bool, mirrorOf: UInt32?, isVirtual: Bool = false) {
        self.id = id
        self.name = name
        self.origin = origin
        self.size = size
        self.isMain = isMain
        self.isBuiltin = isBuiltin
        self.mirrorOf = mirrorOf
        self.isVirtual = isVirtual
    }

    var frame: CGRect { CGRect(origin: origin, size: size) }

    func moved(to origin: CGPoint) -> LayoutDisplay {
        var copy = self
        copy.origin = origin
        return copy
    }
}

enum LayoutMath {
    static let snapDistance: CGFloat = 72

    static func place(_ display: LayoutDisplay, proposed: CGPoint, among others: [LayoutDisplay], drag: CGVector, settle: Bool = true) -> CGPoint {
        var frame = CGRect(origin: proposed, size: display.size)
        guard settle else { return frame.origin }
        frame.origin = snapEdges(frame, to: others)
        frame = resolveOverlaps(frame, others: others, drag: drag)
        if !touchesAny(frame, others: others) {
            frame.origin = attachToCluster(frame, others: others)
            frame = resolveOverlaps(frame, others: others, drag: drag)
        }
        return frame.origin
    }

    static func moveMenuBar(to targetID: UInt32, displays: [LayoutDisplay]) -> [LayoutDisplay] {
        guard let target = displays.first(where: { $0.id == targetID && $0.mirrorOf == nil }) else { return displays }
        let dx = target.origin.x
        let dy = target.origin.y
        return displays.map { item in
            var copy = item
            if copy.mirrorOf == nil {
                copy.origin.x -= dx
                copy.origin.y -= dy
                copy.origin.x = copy.origin.x.rounded()
                copy.origin.y = copy.origin.y.rounded()
            }
            copy.isMain = copy.id == targetID
            return copy
        }
    }

    static func sameArrangement(_ a: [LayoutDisplay], _ b: [LayoutDisplay]) -> Bool {
        guard a.count == b.count else { return false }
        for item in a {
            guard let other = b.first(where: { $0.id == item.id }) else { return false }
            if other.mirrorOf != item.mirrorOf { return false }
            if item.mirrorOf != nil { continue }
            if abs(other.origin.x - item.origin.x) > 0.5 || abs(other.origin.y - item.origin.y) > 0.5 {
                return false
            }
        }
        return true
    }

    private static func snapEdges(_ frame: CGRect, to others: [LayoutDisplay]) -> CGPoint {
        var origin = frame.origin
        var bestX: CGFloat?
        var bestY: CGFloat?
        for other in others where other.mirrorOf == nil {
            let o = other.frame
            let verticalClose = rangesClose(frame.minY, frame.maxY, o.minY, o.maxY)
            let horizontalClose = rangesClose(frame.minX, frame.maxX, o.minX, o.maxX)
            if verticalClose {
                bestX = nearer(bestX, candidates: [
                    o.maxX,                 // our left to their right
                    o.minX - frame.width,   // our right to their left
                    o.minX,                 // align left
                    o.maxX - frame.width    // align right
                ], current: origin.x)
            }
            if horizontalClose {
                bestY = nearer(bestY, candidates: [
                    o.maxY,
                    o.minY - frame.height,
                    o.minY,
                    o.maxY - frame.height
                ], current: origin.y)
            }
        }
        if let bestX { origin.x = bestX }
        if let bestY { origin.y = bestY }
        return origin
    }

    private static func nearer(_ existing: CGFloat?, candidates: [CGFloat], current: CGFloat) -> CGFloat? {
        var best = existing
        var bestDist = existing.map { abs($0 - current) } ?? CGFloat.greatestFiniteMagnitude
        for candidate in candidates {
            let dist = abs(candidate - current)
            if dist <= snapDistance && dist < bestDist {
                best = candidate
                bestDist = dist
            }
        }
        return best
    }

    private static func rangesClose(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> Bool {
        let overlap = min(a1, b1) - max(a0, b0)
        if overlap > -snapDistance { return true }
        return false
    }

    private static func resolveOverlaps(_ frame: CGRect, others: [LayoutDisplay], drag: CGVector) -> CGRect {
        var frame = frame
        let horizontal = abs(drag.dx) >= abs(drag.dy)
        for _ in 0..<6 {
            var hit = false
            for other in others where other.mirrorOf == nil {
                let o = other.frame
                let overlapW = min(frame.maxX, o.maxX) - max(frame.minX, o.minX)
                let overlapH = min(frame.maxY, o.maxY) - max(frame.minY, o.minY)
                guard overlapW > 0.5 && overlapH > 0.5 else { continue }
                hit = true
                if horizontal {
                    frame.origin.x = frame.midX <= o.midX ? o.minX - frame.width : o.maxX
                } else {
                    frame.origin.y = frame.midY <= o.midY ? o.minY - frame.height : o.maxY
                }
            }
            if !hit { break }
        }
        return frame
    }

    private static func touchesAny(_ frame: CGRect, others: [LayoutDisplay]) -> Bool {
        let grown = frame.insetBy(dx: -1.5, dy: -1.5)
        return others.contains { $0.mirrorOf == nil && grown.intersects($0.frame) }
    }

    private static func attachToCluster(_ frame: CGRect, others: [LayoutDisplay]) -> CGPoint {
        var bestOrigin = frame.origin
        var bestDist = CGFloat.greatestFiniteMagnitude
        for other in others where other.mirrorOf == nil {
            let o = other.frame
            let candidates = [
                CGPoint(x: o.maxX, y: frame.minY),
                CGPoint(x: o.minX - frame.width, y: frame.minY),
                CGPoint(x: frame.minX, y: o.maxY),
                CGPoint(x: frame.minX, y: o.minY - frame.height),
                CGPoint(x: o.maxX, y: o.minY),
                CGPoint(x: o.minX - frame.width, y: o.minY),
                CGPoint(x: o.minX, y: o.maxY),
                CGPoint(x: o.minX, y: o.minY - frame.height)
            ]
            for origin in candidates {
                let candidate = CGRect(origin: origin, size: frame.size)
                guard touchesAny(candidate, others: [other]) else { continue }
                guard !overlaps(candidate, others: others) else { continue }
                let dist = hypot(origin.x - frame.origin.x, origin.y - frame.origin.y)
                if dist < bestDist {
                    bestDist = dist
                    bestOrigin = origin
                }
            }
        }
        return bestOrigin
    }

    private static func overlaps(_ frame: CGRect, others: [LayoutDisplay]) -> Bool {
        others.contains { other in
            guard other.mirrorOf == nil else { return false }
            let overlapW = min(frame.maxX, other.frame.maxX) - max(frame.minX, other.frame.minX)
            let overlapH = min(frame.maxY, other.frame.maxY) - max(frame.minY, other.frame.minY)
            return overlapW > 0.5 && overlapH > 0.5
        }
    }
}

enum LayoutSelfTest {
    static func run() -> Bool {
        let main = LayoutDisplay(id: 2, name: "Display A", origin: .zero, size: CGSize(width: 1920, height: 1080), isMain: true, isBuiltin: false, mirrorOf: nil)
        let left = LayoutDisplay(id: 15, name: "Display B", origin: CGPoint(x: -1920, y: 0), size: CGSize(width: 1920, height: 1080), isMain: false, isBuiltin: false, mirrorOf: nil)
        let built = LayoutDisplay(id: 1, name: "Built-in Retina Display", origin: CGPoint(x: 1590, y: 1080), size: CGSize(width: 1680, height: 1050), isMain: false, isBuiltin: true, mirrorOf: nil)
        let all = [main, left, built]

        let nudged = LayoutMath.place(left, proposed: CGPoint(x: -1950, y: 0), among: [main, built], drag: CGVector(dx: -30, dy: 0))
        expect(nudged.x == -1920 && nudged.y == 0, "small left drag snaps back to the main display, got \(nudged)")

        let pushed = LayoutMath.place(left, proposed: CGPoint(x: -1520, y: 0), among: [main, built], drag: CGVector(dx: 400, dy: 0))
        expect(pushed.x == -1920 && pushed.y == 0, "overlap from the left stays on the left, got \(pushed)")

        let parked = LayoutMath.place(left, proposed: CGPoint(x: -3000, y: 40), among: [main, built], drag: CGVector(dx: -1080, dy: 40))
        let parkedFrame = CGRect(origin: parked, size: left.size)
        expect(LayoutMath.sameArrangement([left.moved(to: parked)], [left.moved(to: parked)]), "same check")
        expect(abs(parkedFrame.maxX - main.frame.minX) < 1.5 || abs(parkedFrame.minX - main.frame.maxX) < 1.5 || abs(parkedFrame.maxY - main.frame.minY) < 1.5 || abs(parkedFrame.minY - main.frame.maxY) < 1.5 || parkedFrame.insetBy(dx: -1.5, dy: -1.5).intersects(built.frame), "detached display reattaches, got \(parked)")

        let moved = LayoutMath.moveMenuBar(to: 1, displays: all)
        let newBuilt = moved.first { $0.id == 1 }!
        let newMain = moved.first { $0.id == 2 }!
        let newLeft = moved.first { $0.id == 15 }!
        expect(newBuilt.origin == .zero && newBuilt.isMain, "menu bar display sits at origin")
        expect(newMain.origin == CGPoint(x: -1590, y: -1080), "previous main keeps its offset, got \(newMain.origin)")
        expect(newLeft.origin == CGPoint(x: -3510, y: -1080), "left display keeps its offset, got \(newLeft.origin)")
        expect(LayoutMath.sameArrangement(all, all), "identical layouts match")
        return failures.isEmpty
    }

    private static var failures: [String] = []

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition { failures.append(message); fputs("FAIL \(message)\n", stderr) }
    }
}
