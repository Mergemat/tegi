import CoreGraphics

public struct Workspace: Equatable {
    public let id: Int
    public var home: UInt32
    public var name: String?
    public var columns: [Column] = []
    public var active = 0
    public var viewOffset: Double = 0
    var returnOffset: Double?

    public init(id: Int, home: UInt32) {
        self.id = id
        self.home = home
    }

    public var isEmpty: Bool { columns.isEmpty }
    public var activeWindow: WindowID? { columns.indices.contains(active) ? columns[active].activeWindow : nil }

    func column(of id: WindowID) -> (column: Int, tile: Int)? {
        for (c, col) in columns.enumerated() {
            if let t = col.tiles.firstIndex(where: { $0.id == id }) { return (c, t) }
        }
        return nil
    }

    func widths(_ g: Geometry) -> [Double] { columns.map { $0.resolvedWidth(g) } }

    func columnX(_ i: Int, _ g: Geometry) -> Double {
        var x = 0.0
        for col in columns.prefix(i) { x += col.resolvedWidth(g) + g.gap }
        return x
    }

    func viewPos(_ g: Geometry) -> Double { columnX(active, g) + viewOffset }

    private func fitOffset(_ idx: Int, _ g: Geometry) -> Double {
        let col = columns[idx]
        if col.fullscreen { return 0 }
        let view = g.area.width
        let width = col.resolvedWidth(g)
        if view <= width { return 0 }
        let cur = viewPos(g)
        let x = columnX(idx, g)
        let padding = min(max((view - width) / 2, 0), g.gap)
        let left = x - padding, right = x + width + padding
        if cur <= left && right <= cur + view { return -(x - cur) }
        return abs(cur - left) <= abs(cur + view - right) ? -padding : -(view - padding - width)
    }

    private func centeredOffset(_ idx: Int, _ g: Geometry) -> Double {
        let width = columns[idx].resolvedWidth(g)
        if columns[idx].fullscreen || g.area.width <= width { return fitOffset(idx, g) }
        return -(g.area.width - width) / 2
    }

    private func offset(for idx: Int, from prev: Int?, _ g: Geometry) -> Double {
        if g.config.centerFocusedColumn == .always || (g.config.alwaysCenterSingleColumn && columns.count <= 1) {
            return centeredOffset(idx, g)
        }
        guard g.config.centerFocusedColumn == .onOverflow, let prev, prev != idx else { return fitOffset(idx, g) }
        let source = prev > idx ? min(idx + 1, columns.count - 1) : max(idx - 1, 0)
        let sx = columnX(source, g), tx = columnX(idx, g)
        let span = (sx < tx ? tx - sx + columns[idx].resolvedWidth(g) : sx - tx + columns[source].resolvedWidth(g)) + 2 * g.gap
        return span <= g.area.width ? fitOffset(idx, g) : centeredOffset(idx, g)
    }

    mutating func activate(_ idx: Int, _ g: Geometry) {
        guard !columns.isEmpty, idx != active || active >= columns.count else { return }
        let new = offset(for: idx, from: active, g)
        active = idx
        viewOffset = new
        returnOffset = nil
    }

    mutating func refit(_ g: Geometry) {
        guard columns.indices.contains(active) else { return }
        viewOffset = offset(for: active, from: nil, g)
    }

    mutating func center(_ g: Geometry) {
        guard columns.indices.contains(active) else { return }
        viewOffset = centeredOffset(active, g)
    }

    mutating func addColumn(_ column: Column, at index: Int? = nil, activate: Bool, _ g: Geometry) {
        let wasEmpty = columns.isEmpty
        let idx = index ?? (wasEmpty ? 0 : active + 1)
        columns.insert(column, at: idx)
        if !wasEmpty && idx <= active { active += 1 }
        guard activate else { return }
        if wasEmpty {
            active = idx
            viewOffset = 0
            viewOffset = offset(for: idx, from: nil, g)
            return
        }
        let saved = idx == active + 1 ? viewOffset : nil
        self.activate(idx, g)
        returnOffset = saved
    }

    @discardableResult
    mutating func removeColumn(_ idx: Int, _ g: Geometry) -> Column {
        if idx + 1 == active { returnOffset = nil }
        let removed = columns.remove(at: idx)
        if columns.isEmpty {
            active = 0
            returnOffset = nil
            return removed
        }
        if idx < active {
            active -= 1
            returnOffset = nil
        } else if idx == active, let saved = returnOffset, idx > 0 {
            activate(idx - 1, g)
            viewOffset = saved
            refit(g)
        } else if idx == active && idx == columns.count {
            activate(columns.count - 1, g)
        }
        return removed
    }

    mutating func removeTile(_ c: Int, _ t: Int, _ g: Geometry) -> (tile: Tile, width: Column.Width, fullWidth: Bool) {
        let col = columns[c]
        let tile = col.tiles[t]
        if col.tiles.count == 1 {
            removeColumn(c, g)
        } else {
            columns[c].tiles.remove(at: t)
            if t < col.active || (t == col.active && t == col.tiles.count - 1) { columns[c].active -= 1 }
        }
        return (tile, col.width, col.fullWidth)
    }

    private func scrollBounds(_ g: Geometry) -> (lo: Double, hi: Double) {
        guard !columns.isEmpty else { return (0, 0) }
        let view = g.area.width
        let centering = g.config.centerFocusedColumn == .always
            || (g.config.alwaysCenterSingleColumn && columns.count == 1)
        func inset(_ i: Int) -> Double {
            guard !columns[i].fullscreen else { return 0 }
            let space = max(0, view - columns[i].resolvedWidth(g)) / 2
            return centering ? space : min(space, g.gap)
        }
        let last = columns.count - 1
        let lo = -inset(0)
        let hi = columnX(last, g) + columns[last].resolvedWidth(g) + inset(last) - view
        return (lo, max(lo, hi))
    }

    mutating func scroll(to position: Double, _ g: Geometry) {
        guard !columns.isEmpty else { return }
        let bounds = scrollBounds(g)
        let band = RubberBand(stiffness: 0.55, limit: 80)
        viewOffset = band.clamp(position, bounds.lo, bounds.hi) - columnX(active, g)
    }

    mutating func scrollWithinEnds(by dx: Double, _ g: Geometry) {
        guard !columns.isEmpty else { return }
        let end = columnX(columns.count - 1, g) + columns[columns.count - 1].resolvedWidth(g)
        let lo = -g.gap, hi = end + g.gap - g.area.width
        guard hi > lo else { return }
        let pos = viewPos(g)
        let target = dx > 0 ? min(pos + dx, max(pos, hi)) : max(pos + dx, min(pos, lo))
        viewOffset += target - pos
    }

    mutating func endSwipe(coastingTo target: Double, _ g: Geometry) {
        guard !columns.isEmpty else { return }
        let view = g.area.width
        let widths = widths(g)
        var xs: [Double] = [], x = 0.0
        for width in widths { xs.append(x); x += width + g.gap }
        let bounds = scrollBounds(g)
        let centering = g.config.centerFocusedColumn == .always
            || (g.config.alwaysCenterSingleColumn && columns.count == 1)
        var anchors: [(position: Double, column: Int)] = []
        for i in columns.indices {
            let space = max(0, view - widths[i]) / 2
            let padding = columns[i].fullscreen ? 0 : min(space, g.gap)
            let positions = centering && !columns[i].fullscreen
                ? [xs[i] - space]
                : [xs[i] - padding, xs[i] + widths[i] + padding - view]
            for position in positions {
                anchors.append((min(max(position, bounds.lo), bounds.hi), i))
            }
        }
        let anchor = anchors.min { abs($0.position - target) < abs($1.position - target) }!
        let position = anchor.position

        // Keep focus if its column is fully visible; otherwise choose the most exposed column without moving the view.
        func visible(_ i: Int) -> Double {
            max(0, min(xs[i] + widths[i], position + view) - max(xs[i], position))
        }
        if centering {
            active = anchor.column
        } else if visible(active) < min(widths[active], view) {
            let forward = target >= viewPos(g)
            active = columns.indices.max {
                let a = visible($0), b = visible($1)
                return a == b ? (forward ? $0 < $1 : $0 > $1) : a < b
            } ?? active
        }
        viewOffset = position - xs[active]
        returnOffset = nil
    }

    mutating func focusColumn(_ idx: Int, _ g: Geometry) {
        guard !columns.isEmpty else { return }
        activate(max(0, min(columns.count - 1, idx)), g)
    }

    mutating func focusTile(by delta: Int) -> Bool {
        guard columns.indices.contains(active) else { return false }
        let new = columns[active].active + delta
        guard columns[active].tiles.indices.contains(new) else { return false }
        columns[active].active = new
        return true
    }

    mutating func moveColumn(to newIdx: Int, _ g: Geometry) {
        guard columns.indices.contains(active), columns.indices.contains(newIdx), newIdx != active else { return }
        let oldX = columnX(active, g)
        columns.insert(columns.remove(at: active), at: newIdx)
        viewOffset += oldX - columnX(active, g)
        activate(newIdx, g)
    }

    mutating func focusTile(at index: Int) {
        guard columns.indices.contains(active) else { return }
        columns[active].active = max(0, min(columns[active].tiles.count - 1, index))
    }

    mutating func moveTile(by delta: Int) -> Bool {
        guard columns.indices.contains(active) else { return false }
        let t = columns[active].active, new = t + delta
        guard columns[active].tiles.indices.contains(new) else { return false }
        columns[active].tiles.swapAt(t, new)
        columns[active].active = new
        return true
    }

    mutating func consumeIntoColumn(_ g: Geometry) {
        guard columns.indices.contains(active + 1) else { return }
        let (tile, _, _) = removeTile(active + 1, 0, g)
        columns[active].tiles.append(tile)
    }

    mutating func expelFromColumn(_ g: Geometry) {
        guard columns.indices.contains(active), columns[active].tiles.count > 1 else { return }
        let (tile, width, fullWidth) = removeTile(active, columns[active].tiles.count - 1, g)
        addColumn(Column(tile.id, width: width, fullWidth: fullWidth), at: active + 1, activate: false, g)
    }

    mutating func consumeOrExpel(left: Bool, _ g: Geometry) {
        guard columns.indices.contains(active) else { return }
        let c = active, t = columns[c].active
        if columns[c].tiles.count == 1 {
            let target = left ? c - 1 : c + 1
            guard columns.indices.contains(target) else { return }
            if left {
                returnOffset = returnOffset ?? viewOffset + columnX(c, g) - columnX(c - 1, g)
            } else {
                returnOffset = nil
            }
            let (tile, _, _) = removeTile(c, 0, g)
            let into = left ? c - 1 : c
            columns[into].tiles.append(Tile(id: tile.id))
            columns[into].active = columns[into].tiles.count - 1
            if active != into { activate(into, g) }
        } else {
            let (tile, width, fullWidth) = removeTile(c, t, g)
            addColumn(Column(tile.id, width: width, fullWidth: fullWidth), at: left ? c : c + 1, activate: true, g)
            if left { returnOffset = nil }
        }
    }

    mutating func cycleWidth(forwards: Bool, _ g: Geometry) {
        let presets = g.config.presetColumnWidths
        guard columns.indices.contains(active), !presets.isEmpty else { return }
        var col = columns[active]
        let n = presets.count
        let idx: Int
        if let p = col.presetWidth, !col.fullWidth {
            idx = (p + (forwards ? 1 : n - 1)) % n
        } else {
            let current = col.resolvedWidth(g)
            let resolved = presets.map { p -> Double in
                if case .proportion(let f) = p { return Column.proportionWidth(f, g) }
                if case .fixed(let px) = p { return px }
                return 0
            }
            idx = forwards
                ? resolved.firstIndex { current + 1 < $0 } ?? 0
                : resolved.lastIndex { $0 + 1 < current } ?? n - 1
        }
        col.width = presets[idx]
        col.presetWidth = idx
        col.fullWidth = false
        columns[active] = col
        refit(g)
    }

    mutating func setWidth(_ change: SizeChange, _ g: Geometry) {
        guard columns.indices.contains(active) else { return }
        var col = columns[active]
        let current: Column.Width = col.fullWidth ? .proportion(1) : col.width
        var resolved = col
        resolved.fullWidth = false
        resolved.width = current
        let px = resolved.resolvedWidth(g)
        switch (current, change) {
        case (_, .setFixed(let v)): col.width = .fixed(min(max(v, 1), 100_000))
        case (_, .setProportion(let p)): col.width = .proportion(min(max(p, 0), 100))
        case (_, .adjustFixed(let d)): col.width = .fixed(min(max(px + d, 1), 100_000))
        case (.proportion(let p), .adjustProportion(let d)): col.width = .proportion(min(max(p + d, 0), 100))
        case (.fixed, .adjustProportion(let d)):
            let full = g.area.width - g.gap
            let p = full == 0 ? 1 : (px + g.gap) / full
            col.width = .proportion(min(max(p + d, 0), 100))
        }
        col.presetWidth = nil
        col.fullWidth = false
        columns[active] = col
        refit(g)
    }

    mutating func toggleFullWidth(_ g: Geometry) {
        guard columns.indices.contains(active) else { return }
        columns[active].fullWidth.toggle()
        refit(g)
    }

    private func fullyVisible(_ g: Geometry) -> (indices: [Int], leftX: Double?, taken: Double) {
        let view = viewPos(g)
        var out: [Int] = [], leftX: Double?, taken = 0.0
        for i in columns.indices {
            let x = columnX(i, g), w = columns[i].resolvedWidth(g)
            if x < view + g.gap { continue }
            if leftX == nil { leftX = x }
            if view + g.area.width < x + w + g.gap { break }
            out.append(i)
            taken += w + g.gap
        }
        return (out, leftX, taken)
    }

    mutating func expandToAvailableWidth(_ g: Geometry) {
        guard columns.indices.contains(active), !columns[active].fullWidth, !columns[active].fullscreen else { return }
        if g.config.centerFocusedColumn == .always { return toggleFullWidth(g) }
        let (visible, leftX, taken) = fullyVisible(g)
        guard visible.contains(active), let leftX else { return }
        let available = g.area.width - g.gap - taken
        guard available > 0 else { return }
        if visible == [active] { return toggleFullWidth(g) }
        columns[active].width = .fixed(columns[active].resolvedWidth(g) + available)
        columns[active].presetWidth = nil
        viewOffset = leftX - g.gap - columnX(active, g)
        refit(g)
    }

    mutating func centerVisibleColumns(_ g: Geometry) {
        guard columns.indices.contains(active), g.config.centerFocusedColumn != .always else { return }
        let (visible, leftX, taken) = fullyVisible(g)
        guard visible.contains(active), let leftX else { return }
        let free = g.area.width - taken + g.gap
        viewOffset = leftX - free / 2 - columnX(active, g)
        refit(g)
    }

    mutating func setHeight(_ change: SizeChange, _ g: Geometry) {
        guard columns.indices.contains(active) else { return }
        var col = columns[active]
        let t = col.active
        if case .auto = col.tiles[t].height { col.convertHeightsToAuto(g) }
        let current = col.tileHeights(g)[t]
        let full = g.area.height - g.gap
        let prop = full == 0 ? 1 : (current + g.gap) / full
        var h: Double
        switch change {
        case .setFixed(let v): h = v
        case .adjustFixed(let d): h = current + d
        case .setProportion(let p): h = full * p - g.gap
        case .adjustProportion(let d): h = full * (prop + d) - g.gap
        }
        let others = Double(col.tiles.count - 1) * (1 + g.gap)
        h = min(h, max(1, g.area.height - 2 * g.gap - others))
        col.tiles[t].height = .fixed(min(max(h, 1), 100_000))
        columns[active] = col
    }

    mutating func cycleHeight(_ g: Geometry) {
        let presets = g.config.presetWindowHeights
        guard columns.indices.contains(active), !presets.isEmpty else { return }
        var col = columns[active]
        let t = col.active
        let idx: Int
        if case .preset(let p) = col.tiles[t].height {
            idx = (p + 1) % presets.count
        } else {
            col.convertHeightsToAuto(g)
            let current = col.tileHeights(g)[t]
            idx = presets.map { Column.proportionHeight($0, g) }.firstIndex { current + 1 < $0 } ?? 0
        }
        col.tiles[t].height = .preset(idx)
        columns[active] = col
    }

    mutating func resetHeight() {
        guard columns.indices.contains(active) else { return }
        columns[active].tiles[columns[active].active].height = .auto(weight: 1)
    }

    mutating func toggleTabbed() {
        guard columns.indices.contains(active) else { return }
        columns[active].tabbed.toggle()
    }

    mutating func setTabbed(_ tabbed: Bool) {
        guard columns.indices.contains(active) else { return }
        columns[active].tabbed = tabbed
    }

    mutating func swapWindow(left: Bool, _ g: Geometry) {
        guard columns.indices.contains(active) else { return }
        let target = active + (left ? -1 : 1)
        guard columns.indices.contains(target) else { return }
        if columns[active].tiles.count == 1 && columns[target].tiles.count == 1 { return moveColumn(to: target, g) }
        let s = columns[active].active, t = columns[target].active
        let mine = columns[active].tiles[s]
        columns[active].tiles[s] = columns[target].tiles[t]
        columns[target].tiles[t] = mine
        activate(target, g)
    }

    mutating func toggleFullscreen(_ g: Geometry) {
        guard columns.indices.contains(active) else { return }
        if !columns[active].fullscreen && columns[active].tiles.count > 1 && !columns[active].tabbed {
            consumeOrExpel(left: false, g)
        }
        columns[active].fullscreen.toggle()
        refit(g)
    }
}
