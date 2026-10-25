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
    let c = try Config.parse("switcher-shows icons\nswitcher-windows workspace\nswitcher-delay 0\nswitcher-mascot off")
    #expect(c.switcherShows == .icons)
    #expect(c.switcherWindows == .workspace)
    #expect(c.switcherDelay == 0)
    #expect(!c.switcherMascot)
    #expect(Config.builtIn.switcherShows == .pictures && Config.builtIn.switcherWindows == .everywhere)
    #expect(Config.builtIn.switcherDelay == 0.15 && Config.builtIn.switcherMascot)
}

@Test func theCheatSheetCanShowEveryLaunchOrNever() throws {
    #expect(try Config.parse("hotkey-overlay-at-startup always").hotkeyOverlayAtStartup == .always)
    #expect(try Config.parse("hotkey-overlay-at-startup never").hotkeyOverlayAtStartup == .never)
    #expect(Config.builtIn.hotkeyOverlayAtStartup == .firstTime)
}
