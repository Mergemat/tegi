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
            return Array(repeating: min(max(1, h), full), count: tiles.count)
        }
        let n = Double(tiles.count)
        let autoCount = tiles.filter { explicit($0.height) == nil }.count
        var left = max(n, g.area.height - g.gap * (n + 1))
        var out: [Double?] = Array(repeating: nil, count: tiles.count)
        var unallocated = tiles.count
        for i in tiles.indices {
            guard let h = explicit(tiles[i].height) else { continue }
            unallocated -= 1
            out[i] = min(max(1, h), max(1, left - Double(unallocated)))
            left -= out[i]!
        }
        var weightLeft = tiles.reduce(0.0) { sum, t in
            if case .auto(let w) = t.height, explicit(t.height) == nil { return sum + w }
            return sum
        }
        var autosLeft = autoCount
        for i in tiles.indices where out[i] == nil {
            guard case .auto(let w) = tiles[i].height else { continue }
            let h = autosLeft == 1 ? left : (left * w / max(weightLeft, .ulpOfOne)).rounded(.down)
            out[i] = max(1, h)
            left -= h
            weightLeft -= w
            autosLeft -= 1
        }
        return out.map { $0 ?? 1 }
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
