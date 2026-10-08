//
//  TrailPath.swift
//  SlackowWall
//

import CoreGraphics
import Foundation

/// Builds the cursor trail as a single filled outline: a smooth ribbon that tapers from
/// a point at the tail to `width` at the cursor, with a rounded head.
/// Filling one outline (instead of stroking many segments) means nothing overlaps,
/// so there are no seams, beads or width steps.
enum TrailPath {
    static func ribbon(points raw: [CGPoint], width: CGFloat) -> CGPath? {
        let points = smooth(dedupe(raw, minDistance: 1.5), iterations: 3)
        guard points.count > 1 else { return nil }

        let n = points.count
        var left: [CGPoint] = []
        var right: [CGPoint] = []
        left.reserveCapacity(n)
        right.reserveCapacity(n)

        for i in 0..<n {
            let prev = points[max(i - 1, 0)]
            let next = points[min(i + 1, n - 1)]
            var tx = next.x - prev.x
            var ty = next.y - prev.y
            let len = max(hypot(tx, ty), 0.0001)
            tx /= len
            ty /= len
            let progress = CGFloat(i) / CGFloat(n - 1)
            // Ease the taper so the trail stays full for longer near the cursor.
            let half = width / 2 * (1 - pow(1 - progress, 2))
            left.append(CGPoint(x: points[i].x - ty * half, y: points[i].y + tx * half))
            right.append(CGPoint(x: points[i].x + ty * half, y: points[i].y - tx * half))
        }

        let path = CGMutablePath()
        path.addLines(between: left)

        // Rounded head: half circle from the left edge, around the front, to the right edge.
        let head = points[n - 1]
        let startAngle = atan2(left[n - 1].y - head.y, left[n - 1].x - head.x)
        path.addArc(
            center: head, radius: width / 2, startAngle: startAngle,
            endAngle: startAngle - .pi, clockwise: true)

        for point in right.reversed() {
            path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }

    /// Drops samples that are almost on top of each other; they make the direction jittery.
    static func dedupe(_ points: [CGPoint], minDistance: CGFloat) -> [CGPoint] {
        guard let last = points.last else { return [] }
        var result: [CGPoint] = []
        for point in points.dropLast() {
            if let previous = result.last,
                hypot(point.x - previous.x, point.y - previous.y) < minDistance
            {
                continue
            }
            result.append(point)
        }
        // Always end exactly at the cursor.
        if let previous = result.last, hypot(last.x - previous.x, last.y - previous.y) < minDistance {
            result.removeLast()
        }
        result.append(last)
        return result
    }

    /// Chaikin corner cutting: rounds corners without ever overshooting the original path.
    /// The first and last points are kept so the trail still ends at the cursor.
    static func smooth(_ points: [CGPoint], iterations: Int) -> [CGPoint] {
        var current = points
        for _ in 0..<iterations {
            guard current.count > 2 else { return current }
            var next: [CGPoint] = [current[0]]
            for i in 0..<(current.count - 1) {
                let a = current[i]
                let b = current[i + 1]
                next.append(CGPoint(x: 0.75 * a.x + 0.25 * b.x, y: 0.75 * a.y + 0.25 * b.y))
                next.append(CGPoint(x: 0.25 * a.x + 0.75 * b.x, y: 0.25 * a.y + 0.75 * b.y))
            }
            next.append(current[current.count - 1])
            current = next
        }
        return current
    }
}
