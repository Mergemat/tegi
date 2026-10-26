import CoreGraphics

public typealias WindowID = Int

public struct Tile: Equatable {
    public enum Height: Equatable {
        case auto(weight: Double)
        case fixed(Double)
        case preset(Int)
    }

    public var id: WindowID
    public var height: Height = .auto(weight: 1)
}

public struct Column: Equatable {
    public enum Width: Equatable { case proportion(Double), fixed(Double) }

    public var tiles: [Tile]
    public var active = 0
    public var width: Width
    public var presetWidth: Int?
    public var fullWidth = false
    public var fullscreen = false
    public var tabbed = false

    public init(_ id: WindowID, width: Width, fullWidth: Bool = false) {
        tiles = [Tile(id: id)]
        self.width = width
        self.fullWidth = fullWidth
    }

    public var windows: [WindowID] { tiles.map(\.id) }
    public var activeWindow: WindowID { tiles[active].id }
}

struct Geometry {
    var area: CGRect
    var config: Config
    var heightLimits: [WindowID: CGSize] = [:]
    var gap: Double { config.gap }
}

extension Column {
    func resolvedWidth(_ g: Geometry) -> Double {
        if fullscreen { return g.area.width }
        if fullWidth { return Self.proportionWidth(1, g) }
        switch width {
        case .proportion(let p): return Self.proportionWidth(p, g)
        case .fixed(let px): return min(max(px, 1), 100_000)
        }
    }

    static func proportionWidth(_ p: Double, _ g: Geometry) -> Double {
        max(1, ((g.area.width - g.gap) * p - g.gap).rounded(.down))
    }

    static func proportionHeight(_ p: Double, _ g: Geometry) -> Double {
        max(1, ((g.area.height - g.gap) * p - g.gap).rounded(.down))
    }

    func tileHeights(_ g: Geometry) -> [Double] {
        if fullscreen { return Array(repeating: g.area.height, count: tiles.count) }
        let full = max(1, g.area.height - 2 * g.gap)
        let width = resolvedWidth(g)
        let minimums = tiles.map { tile -> Double in
            // Responsive apps can accept a smaller height at a different width.
            guard let limit = g.heightLimits[tile.id], abs(limit.width - width) <= 1 else { return 1 }
            return max(1, limit.height.rounded(.up))
        }
        func explicit(_ h: Tile.Height) -> Double? {
            switch h {
            case .auto: return nil
            case .fixed(let px): return px
            case .preset(let i):
                let presets = g.config.presetWindowHeights
                return presets.indices.contains(i) ? Self.proportionHeight(presets[i], g) : nil
            }
        }
        if tabbed {
            let h = tiles.lazy.compactMap { explicit($0.height) }.first ?? full
            return minimums.map { max($0, min(max(1, h), full)) }
        }
        let n = Double(tiles.count)
        var reserved = minimums.reduce(0, +)
        var left = max(reserved, g.area.height - g.gap * (n + 1))
        var out: [Double?] = Array(repeating: nil, count: tiles.count)
        for i in tiles.indices {
            guard let h = explicit(tiles[i].height) else { continue }
            reserved -= minimums[i]
            out[i] = min(max(minimums[i], h), left - reserved)
            left -= out[i]!
        }
        var autos = tiles.indices.filter { out[$0] == nil }
        func weight(_ i: Int) -> Double {
            if case .auto(let w) = tiles[i].height { return w }
            return 1
        }
        while !autos.isEmpty {
            var weightLeft = max(autos.reduce(0) { $0 + weight($1) }, .ulpOfOne)
            let constrained = autos.filter { left * weight($0) / weightLeft < minimums[$0] }
            if !constrained.isEmpty {
                for i in constrained { out[i] = minimums[i]; left -= minimums[i] }
                autos.removeAll { out[$0] != nil }
                continue
            }
            for (index, i) in autos.enumerated() {
                let h = index == autos.count - 1 ? left : (left * weight(i) / weightLeft).rounded(.down)
                out[i] = max(minimums[i], h)
                left -= out[i]!
                weightLeft -= weight(i)
            }
            break
        }
        return out.map { $0 ?? 1 }
    }

    func heightOffset(_ heights: [Double], _ g: Geometry) -> Double {
        guard !fullscreen, !tabbed, heights.indices.contains(active) else { return 0 }
        let top = heights.prefix(active).reduce(0, +) + Double(active) * g.gap
        return max(0, min(top, top + heights[active] - (g.area.height - 2 * g.gap)))
    }

    mutating func convertHeightsToAuto(_ g: Geometry) {
        let heights = tileHeights(g)
        let median = heights.sorted()[heights.count / 2]
        for i in tiles.indices { tiles[i].height = .auto(weight: heights[i] / median) }
    }
}

public enum SizeChange: Equatable {
    case setProportion(Double), adjustProportion(Double)
    case setFixed(Double), adjustFixed(Double)

    public init?(_ s: String) {
        let relative = s.hasPrefix("+") || s.hasPrefix("-")
        if s.hasSuffix("%") {
            guard let v = Double(s.dropLast()) else { return nil }
            self = relative ? .adjustProportion(v / 100) : .setProportion(v / 100)
        } else {
            guard let v = Double(s) else { return nil }
            self = relative ? .adjustFixed(v) : .setFixed(v)
        }
    }
}
