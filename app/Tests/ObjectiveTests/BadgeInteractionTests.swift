import Testing
@testable import Objective

@Suite struct BadgeInteractionTests {
    @Test func clickOpensCollapsedBoard() {
        var state = BadgeInteractionState()
        state.mouseDown()

        let shouldOpen = state.mouseUpShouldOpen()
        #expect(shouldOpen)
    }

    @Test func dragKeepsCollapsedBoardClosed() {
        var state = BadgeInteractionState()
        state.mouseDown()

        let didDrag = state.mouseDragged(deltaX: 12, deltaY: -8)
        let shouldOpen = state.mouseUpShouldOpen()
        #expect(didDrag)
        #expect(!shouldOpen)
    }
}
