public enum Direction: String, Equatable {
    case left, right, up, down
    case next, previous
}

public enum WorkspaceRef: Equatable, ExpressibleByIntegerLiteral {
    case index(Int)
    case name(String)

    public init(integerLiteral n: Int) { self = .index(n) }

    init(_ s: String) {
        if let n = Int(s), n >= 1 { self = .index(n) } else { self = .name(s) }
    }
}

public enum Command: Equatable {
    case focusColumnLeft, focusColumnRight, focusColumnFirst, focusColumnLast, focusColumn(Int)
    case focusColumnRightOrFirst, focusColumnLeftOrLast
    case focusColumnOrMonitorLeft, focusColumnOrMonitorRight
    case focusWindowUp, focusWindowDown, focusWindowTop, focusWindowBottom, focusWindowInColumn(Int)
    case focusWindowDownOrTop, focusWindowUpOrBottom
    case focusWindowDownOrColumnLeft, focusWindowDownOrColumnRight, focusWindowUpOrColumnLeft, focusWindowUpOrColumnRight
    case focusWindowOrWorkspaceUp, focusWindowOrWorkspaceDown, focusWindowOrMonitorUp, focusWindowOrMonitorDown
    case focusWorkspaceUp, focusWorkspaceDown, focusWorkspace(WorkspaceRef), focusWorkspacePrevious
    case moveColumnLeft, moveColumnRight, moveColumnToFirst, moveColumnToLast, moveColumnToIndex(Int)
    case moveColumnLeftOrToMonitorLeft, moveColumnRightOrToMonitorRight
    case moveWindowUp, moveWindowDown, moveWindowUpOrToWorkspaceUp, moveWindowDownOrToWorkspaceDown
    case swapWindowLeft, swapWindowRight
    case moveColumnToWorkspaceUp, moveColumnToWorkspaceDown, moveColumnToWorkspace(WorkspaceRef)
    case moveWindowToWorkspaceUp, moveWindowToWorkspaceDown, moveWindowToWorkspace(WorkspaceRef)
    case moveWorkspaceUp, moveWorkspaceDown, moveWorkspaceToIndex(Int)
    case setWorkspaceName(String), unsetWorkspaceName
    case focusMonitor(Direction), moveColumnToMonitor(Direction), moveWindowToMonitor(Direction), moveWorkspaceToMonitor(Direction)
    case consumeWindowIntoColumn, expelWindowFromColumn, consumeOrExpelWindowLeft, consumeOrExpelWindowRight
    case switchPresetColumnWidth, switchPresetColumnWidthBack, switchPresetWindowHeight, resetWindowHeight
    case setColumnWidth(SizeChange), setWindowHeight(SizeChange)
    case maximizeColumn, maximizeWindowToEdges, expandColumnToAvailableWidth, fullscreenWindow
    case toggleColumnTabbedDisplay, setColumnDisplay(tabbed: Bool)
    case centerColumn, centerWindow, centerVisibleColumns
    case toggleWindowFloating, moveWindowToFloating, moveWindowToTiling
    case focusFloating, focusTiling, switchFocusBetweenFloatingAndTiling
    case focusWindowPrevious, nextWindow(sameApp: Bool), previousWindow(sameApp: Bool)
    case closeWindow, showHotkeyOverlay, showSettings(String?)
    case toggleOverview, openOverview, closeOverview
    case spawn([String]), spawnSh(String), quit

    public static let simple: [String: Command] = [
        "focus-column-left": .focusColumnLeft, "focus-column-right": .focusColumnRight,
        "focus-column-first": .focusColumnFirst, "focus-column-last": .focusColumnLast,
        "focus-column-right-or-first": .focusColumnRightOrFirst, "focus-column-left-or-last": .focusColumnLeftOrLast,
        "focus-column-or-monitor-left": .focusColumnOrMonitorLeft,
        "focus-column-or-monitor-right": .focusColumnOrMonitorRight,
        "focus-window-up": .focusWindowUp, "focus-window-down": .focusWindowDown,
        "focus-window-top": .focusWindowTop, "focus-window-bottom": .focusWindowBottom,
        "focus-window-down-or-top": .focusWindowDownOrTop, "focus-window-up-or-bottom": .focusWindowUpOrBottom,
        "focus-window-down-or-column-left": .focusWindowDownOrColumnLeft,
        "focus-window-down-or-column-right": .focusWindowDownOrColumnRight,
        "focus-window-up-or-column-left": .focusWindowUpOrColumnLeft,
        "focus-window-up-or-column-right": .focusWindowUpOrColumnRight,
        "focus-window-or-workspace-up": .focusWindowOrWorkspaceUp,
        "focus-window-or-workspace-down": .focusWindowOrWorkspaceDown,
        "focus-window-or-monitor-up": .focusWindowOrMonitorUp,
        "focus-window-or-monitor-down": .focusWindowOrMonitorDown,
        "focus-workspace-up": .focusWorkspaceUp, "focus-workspace-down": .focusWorkspaceDown,
        "focus-workspace-previous": .focusWorkspacePrevious,
        "move-column-left": .moveColumnLeft, "move-column-right": .moveColumnRight,
        "move-column-to-first": .moveColumnToFirst, "move-column-to-last": .moveColumnToLast,
        "move-column-left-or-to-monitor-left": .moveColumnLeftOrToMonitorLeft,
        "move-column-right-or-to-monitor-right": .moveColumnRightOrToMonitorRight,
        "move-window-up": .moveWindowUp, "move-window-down": .moveWindowDown,
        "move-window-up-or-to-workspace-up": .moveWindowUpOrToWorkspaceUp,
        "move-window-down-or-to-workspace-down": .moveWindowDownOrToWorkspaceDown,
        "swap-window-left": .swapWindowLeft, "swap-window-right": .swapWindowRight,
        "move-column-to-workspace-up": .moveColumnToWorkspaceUp,
        "move-column-to-workspace-down": .moveColumnToWorkspaceDown,
        "move-window-to-workspace-up": .moveWindowToWorkspaceUp,
        "move-window-to-workspace-down": .moveWindowToWorkspaceDown,
        "move-workspace-up": .moveWorkspaceUp, "move-workspace-down": .moveWorkspaceDown,
        "unset-workspace-name": .unsetWorkspaceName,
        "consume-window-into-column": .consumeWindowIntoColumn,
        "expel-window-from-column": .expelWindowFromColumn,
        "consume-or-expel-window-left": .consumeOrExpelWindowLeft,
        "consume-or-expel-window-right": .consumeOrExpelWindowRight,
        "switch-preset-column-width": .switchPresetColumnWidth,
        "switch-preset-column-width-back": .switchPresetColumnWidthBack,
        "switch-preset-window-height": .switchPresetWindowHeight,
        "reset-window-height": .resetWindowHeight,
        "maximize-column": .maximizeColumn, "maximize-window-to-edges": .maximizeWindowToEdges,
        "expand-column-to-available-width": .expandColumnToAvailableWidth,
        "fullscreen-window": .fullscreenWindow,
        "toggle-column-tabbed-display": .toggleColumnTabbedDisplay,
        "center-column": .centerColumn, "center-window": .centerWindow, "center-visible-columns": .centerVisibleColumns,
        "toggle-window-floating": .toggleWindowFloating,
        "move-window-to-floating": .moveWindowToFloating, "move-window-to-tiling": .moveWindowToTiling,
        "focus-floating": .focusFloating, "focus-tiling": .focusTiling,
        "switch-focus-between-floating-and-tiling": .switchFocusBetweenFloatingAndTiling,
        "focus-window-previous": .focusWindowPrevious,
        "close-window": .closeWindow, "show-hotkey-overlay": .showHotkeyOverlay, "show-settings": .showSettings(nil),
        "toggle-overview": .toggleOverview, "open-overview": .openOverview, "close-overview": .closeOverview,
        "quit": .quit,
    ]

    public init?<S: Collection<String>>(_ words: S) {
        guard let name = words.first else { return nil }
        let rest = Array(words.dropFirst())
        if rest.isEmpty, let c = Command.simple[name] { self = c; return }
        if rest.isEmpty {
            for (prefix, make) in [("focus-monitor-", Command.focusMonitor), ("move-column-to-monitor-", Command.moveColumnToMonitor),
                                   ("move-window-to-monitor-", Command.moveWindowToMonitor),
                                   ("move-workspace-to-monitor-", Command.moveWorkspaceToMonitor)] where name.hasPrefix(prefix) {
                guard let d = Direction(rawValue: String(name.dropFirst(prefix.count))) else { return nil }
                self = make(d)
                return
            }
        }
        switch name {
        case "spawn" where !rest.isEmpty:
            self = .spawn(rest)
            return
        case "spawn-sh" where !rest.isEmpty:
            self = .spawnSh(rest.joined(separator: " "))
            return
        case "next-window", "previous-window":
            guard rest.isEmpty || rest == ["same-app"] else { return nil }
            self = name == "next-window" ? .nextWindow(sameApp: !rest.isEmpty) : .previousWindow(sameApp: !rest.isEmpty)
            return
        default:
            break
        }
        guard rest.count == 1 else { return nil }
        let arg = rest[0]
        switch name {
        case "set-column-width", "set-window-height":
            guard let change = SizeChange(arg) else { return nil }
            self = name == "set-column-width" ? .setColumnWidth(change) : .setWindowHeight(change)
        case "focus-workspace": self = .focusWorkspace(WorkspaceRef(arg))
        case "move-column-to-workspace": self = .moveColumnToWorkspace(WorkspaceRef(arg))
        case "move-window-to-workspace": self = .moveWindowToWorkspace(WorkspaceRef(arg))
        case "set-workspace-name": self = .setWorkspaceName(arg)
        case "show-settings": self = .showSettings(arg)
        case "set-column-display":
            guard arg == "tabbed" || arg == "normal" else { return nil }
            self = .setColumnDisplay(tabbed: arg == "tabbed")
        case "focus-column", "focus-window-in-column", "move-column-to-index", "move-workspace-to-index":
            guard let n = Int(arg), n >= 1 else { return nil }
            switch name {
            case "focus-column": self = .focusColumn(n)
            case "focus-window-in-column": self = .focusWindowInColumn(n)
            case "move-column-to-index": self = .moveColumnToIndex(n)
            default: self = .moveWorkspaceToIndex(n)
            }
        default:
            return nil
        }
    }

    public var isPlatform: Bool {
        switch self {
        case .toggleWindowFloating, .moveWindowToFloating, .moveWindowToTiling, .focusFloating, .focusTiling,
             .switchFocusBetweenFloatingAndTiling, .focusWindowPrevious, .nextWindow, .previousWindow, .closeWindow,
             .showHotkeyOverlay, .showSettings, .toggleOverview, .openOverview, .closeOverview, .spawn, .spawnSh, .quit:
            return true
        default:
            return false
        }
    }
}
