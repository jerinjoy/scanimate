import XCTest
@testable import Scanimate

/// The draw, move and resize maths behind the ScanRegion the user draws on the Overview.
final class ScanRegionTests: XCTestCase {

    // 850 x 1100 pt shows the 8500 x 11000 Platen at 10 WSD units per point.
    private let container = CGSize(width: 850, height: 1100)
    private let expected = ScanRegion(xOffset: 1000, yOffset: 2000, width: 3000, height: 4000)

    private func drag(from start: CGPoint, to current: CGPoint) -> ScanRegion? {
        ScanRegion.fromDrag(start: start, current: current, containerSize: container)
    }

    // MARK: - fromDrag: each drag direction

    func testDragDownRight() {
        XCTAssertEqual(drag(from: CGPoint(x: 100, y: 200), to: CGPoint(x: 400, y: 600)), expected)
    }

    func testDragUpLeft() {
        XCTAssertEqual(drag(from: CGPoint(x: 400, y: 600), to: CGPoint(x: 100, y: 200)), expected)
    }

    func testDragUpRight() {
        XCTAssertEqual(drag(from: CGPoint(x: 100, y: 600), to: CGPoint(x: 400, y: 200)), expected)
    }

    func testDragDownLeft() {
        XCTAssertEqual(drag(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 100, y: 600)), expected)
    }

    func testConvertsToWSDUnitsForAnyContainerSize() {
        let region = ScanRegion.fromDrag(
            start: CGPoint(x: 42.5, y: 55),
            current: CGPoint(x: 212.5, y: 275),
            containerSize: CGSize(width: 425, height: 550)
        )
        XCTAssertEqual(region, ScanRegion(xOffset: 850, yOffset: 1100, width: 3400, height: 4400))
    }

    // MARK: - fromDrag: clamping to the Platen

    func testClampsAtLeftEdge() {
        XCTAssertEqual(
            drag(from: CGPoint(x: 400, y: 200), to: CGPoint(x: -50, y: 600)),
            ScanRegion(xOffset: 0, yOffset: 2000, width: 4000, height: 4000)
        )
    }

    func testClampsAtTopEdge() {
        XCTAssertEqual(
            drag(from: CGPoint(x: 100, y: 600), to: CGPoint(x: 400, y: -50)),
            ScanRegion(xOffset: 1000, yOffset: 0, width: 3000, height: 6000)
        )
    }

    func testClampsAtRightEdge() {
        XCTAssertEqual(
            drag(from: CGPoint(x: 100, y: 200), to: CGPoint(x: 900, y: 600)),
            ScanRegion(xOffset: 1000, yOffset: 2000, width: 7500, height: 4000)
        )
    }

    func testClampsAtBottomEdge() {
        XCTAssertEqual(
            drag(from: CGPoint(x: 100, y: 200), to: CGPoint(x: 400, y: 1200)),
            ScanRegion(xOffset: 1000, yOffset: 2000, width: 3000, height: 9000)
        )
    }

    func testDragPastOppositeCornersCoversWholePlaten() {
        XCTAssertEqual(
            drag(from: CGPoint(x: -20, y: -20), to: CGPoint(x: 2000, y: 2000)),
            ScanRegion(xOffset: 0, yOffset: 0, width: 8500, height: 11000)
        )
    }

    // MARK: - fromDrag: minimum-size rule

    func testDragNarrowerThanMinimumIsDiscarded() {
        // 49 pt = 490 units wide, tall enough.
        XCTAssertNil(drag(from: CGPoint(x: 100, y: 200), to: CGPoint(x: 149, y: 600)))
    }

    func testDragShorterThanMinimumIsDiscarded() {
        XCTAssertNil(drag(from: CGPoint(x: 100, y: 200), to: CGPoint(x: 400, y: 249)))
    }

    func testStrayClickIsDiscarded() {
        XCTAssertNil(drag(from: CGPoint(x: 100, y: 200), to: CGPoint(x: 103, y: 202)))
    }

    func testDragOfExactlyMinimumSizeIsKept() {
        XCTAssertEqual(
            drag(from: CGPoint(x: 100, y: 200), to: CGPoint(x: 150, y: 250)),
            ScanRegion(xOffset: 1000, yOffset: 2000, width: 500, height: 500)
        )
    }

    func testMinimumAppliesAfterClamping() {
        // 100 pt of drag, but only 30 pt of it lies on the Platen.
        XCTAssertNil(drag(from: CGPoint(x: 820, y: 200), to: CGPoint(x: 920, y: 600)))
    }

    func testEmptyContainerYieldsNoRegion() {
        XCTAssertNil(ScanRegion.fromDrag(
            start: CGPoint(x: 0, y: 0), current: CGPoint(x: 100, y: 100), containerSize: .zero
        ))
    }

    // MARK: - Handle resize maths

    private let start = ScanRegion(xOffset: 1000, yOffset: 2000, width: 3000, height: 4000)

    func testBottomRightHandleGrowsRegion() {
        XCTAssertEqual(
            Handle.bottomRight.updatedRegion(start: start, dx: 500, dy: 700, minSize: 500),
            ScanRegion(xOffset: 1000, yOffset: 2000, width: 3500, height: 4700)
        )
    }

    func testTopLeftHandleMovesOriginAndKeepsOppositeCorner() {
        XCTAssertEqual(
            Handle.topLeft.updatedRegion(start: start, dx: 500, dy: 700, minSize: 500),
            ScanRegion(xOffset: 1500, yOffset: 2700, width: 2500, height: 3300)
        )
    }

    func testEdgeHandleChangesOneSideOnly() {
        XCTAssertEqual(
            Handle.right.updatedRegion(start: start, dx: 500, dy: 700, minSize: 500),
            ScanRegion(xOffset: 1000, yOffset: 2000, width: 3500, height: 4000)
        )
    }

    func testHandleCannotShrinkBelowMinimumSize() {
        XCTAssertEqual(
            Handle.bottomRight.updatedRegion(start: start, dx: -9000, dy: -9000, minSize: 500),
            ScanRegion(xOffset: 1000, yOffset: 2000, width: 500, height: 500)
        )
    }

    func testHandleClampsToPlaten() {
        XCTAssertEqual(
            Handle.bottomRight.updatedRegion(start: start, dx: 99_000, dy: 99_000, minSize: 500),
            ScanRegion(xOffset: 1000, yOffset: 2000, width: 7500, height: 9000)
        )
        XCTAssertEqual(
            Handle.topLeft.updatedRegion(start: start, dx: -99_000, dy: -99_000, minSize: 500),
            ScanRegion(xOffset: 0, yOffset: 0, width: 4000, height: 6000)
        )
    }
}
