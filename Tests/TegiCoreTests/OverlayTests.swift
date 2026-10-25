import Testing
@testable import TegiCore

@Test func theHotCornerCanBeAnyCornerOrOff() throws {
    #expect(try Config.parse("hot-corner top-right").hotCorner == .topRight)
    #expect(try Config.parse("hot-corner off").hotCorner == nil)
    // Configs from before corners could be picked said on.
    #expect(try Config.parse("hot-corner on").hotCorner == .topLeft)
    #expect(Config.builtIn.hotCorner == .topLeft)
}

@Test func theSwitcherCanShowIconsFromOneWorkspaceAtOnce() throws {
    let c = try Config.parse("switcher-shows icons\nswitcher-windows workspace\nswitcher-delay 0\nswitcher-mascot on")
    #expect(c.switcherShows == .icons)
    #expect(c.switcherWindows == .workspace)
    #expect(c.switcherDelay == 0)
    #expect(c.switcherMascot)
    #expect(Config.builtIn.switcherShows == .pictures && Config.builtIn.switcherWindows == .everywhere)
    #expect(Config.builtIn.switcherDelay == 0.15 && !Config.builtIn.switcherMascot)
}

@Test func theCheatSheetCanShowEveryLaunchOrNever() throws {
    #expect(try Config.parse("hotkey-overlay-at-startup always").hotkeyOverlayAtStartup == .always)
    #expect(try Config.parse("hotkey-overlay-at-startup never").hotkeyOverlayAtStartup == .never)
    #expect(Config.builtIn.hotkeyOverlayAtStartup == .firstTime)
}

@Test func theOverviewCanBeTunedToTaste() throws {
    let c = try Config.parse("""
    overview-gap 0.2
    overview-workspace-radius 0
    overview-labels off
    overview-icons off
    overview-backdrop color
    """)
    #expect(c.overviewGap == 0.2)
    #expect(c.overviewWorkspaceRadius == 0)
    #expect(!c.overviewLabels && !c.overviewIcons)
    #expect(c.overviewBackdrop == .color)
    let d = Config.builtIn
    #expect(d.overviewGap == 0.1 && d.overviewWorkspaceRadius == 14 && d.overviewLabels && d.overviewIcons && d.overviewBackdrop == .wallpaper)
}

@Test func theSwitcherCanBeSizedAndLeaveOutNames() throws {
    let c = try Config.parse("switcher-size 320\nswitcher-names off")
    #expect(c.switcherSize == 320)
    #expect(!c.switcherNames)
    #expect(Config.builtIn.switcherSize == 220 && Config.builtIn.switcherNames)
    #expect(throws: ConfigError.self) { try Config.parse("switcher-size 20") }
}

@Test func theSwitcherCanShowPicturesWithTheirAppIcons() throws {
    #expect(try Config.parse("switcher-shows both").switcherShows == .both)
}
