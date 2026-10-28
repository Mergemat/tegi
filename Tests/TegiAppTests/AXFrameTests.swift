import AppKit
import Testing
@testable import tegi

@Test func aSuccessfulResizeDoesNotTreatThePreviousTitleBarHeightAsAMinimum() {
    let requested = CGSize(width: 554, height: 1052)
    var replies = [CGSize(width: 554, height: 1084), requested]
    let answer = confirmedResize(to: requested) { (replies.removeFirst(), .success) }
    #expect(answer.size == requested)
    #expect(answer.error == .success)
}

@Test func aConfirmedMinimumSizeIsPreserved() {
    let requested = CGSize(width: 554, height: 400)
    let minimum = CGSize(width: 554, height: 550)
    let answer = confirmedResize(to: requested) { (minimum, .success) }
    #expect(answer.size == minimum)
}

@Test func aFailedResizeIsNotRetriedAsThoughItSucceeded() {
    var attempts = 0
    let answer = confirmedResize(to: CGSize(width: 554, height: 1052)) {
        attempts += 1
        return (CGSize(width: 554, height: 1084), .cannotComplete)
    }
    #expect(answer.size == nil)
    #expect(answer.error == .cannotComplete)
    #expect(attempts == 1)
}
