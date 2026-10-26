import CoreFoundation
import AppKit
import Testing
import TegiCore
@testable import tegi

@MainActor @Test func anOldAccessibilityCompletionCannotFinishANewerMove() {
    let manager = WindowManager(config: .builtIn)
    manager.generation[1] = 2
    manager.unlanded.insert(1)
    let press = CFAbsoluteTimeGetCurrent()
    manager.pressed = press
    manager.placed(1, generation: 1)
    #expect(manager.unlanded.contains(1))
    #expect(manager.pressed == press)
    manager.placed(1, generation: 2)
    #expect(!manager.unlanded.contains(1))
    #expect(manager.pressed == nil)
}
