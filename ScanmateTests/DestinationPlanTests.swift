import XCTest
@testable import Scanimate

/// The pure planning function: what writing to a Destination will do.
final class DestinationPlanTests: XCTestCase {

    private let folder = URL(fileURLWithPath: "/nonexistent-scanimate-tests/Scans", isDirectory: true)

    private func plan(
        name: String = "Scan",
        type: FileType = .pdf,
        folder: URL?,
        existing: Set<String> = []
    ) -> DestinationPlan {
        Destination(name: name, fileType: type, folder: folder)
            .plan { existing.contains($0.lastPathComponent) }
    }

    // MARK: Create

    func testCreatesAtTheNameWhenNothingIsThere() {
        let plan = plan(folder: folder)

        XCTAssertEqual(plan, .create(folder.appendingPathComponent("Scan.pdf")))
        XCTAssertEqual(plan.url, folder.appendingPathComponent("Scan.pdf"))
        XCTAssertFalse(plan.isBlocked)
        XCTAssertEqual(plan.caption, "Will create Scan.pdf")
    }

    func testEachFileTypeGetsItsExtension() {
        let names = FileType.allCases.map { plan(type: $0, folder: folder).url?.lastPathComponent }
        XCTAssertEqual(names, ["Scan.pdf", "Scan.png", "Scan.jpg", "Scan.tiff"])
    }

    func testATypedExtensionMatchingTheFileTypeIsStripped() {
        XCTAssertEqual(plan(name: "Invoice.pdf", type: .pdf, folder: folder).url?.lastPathComponent, "Invoice.pdf")
        XCTAssertEqual(plan(name: "Invoice.PDF", type: .pdf, folder: folder).url?.lastPathComponent, "Invoice.pdf")
        XCTAssertEqual(plan(name: "Photo.jpeg", type: .jpeg, folder: folder).url?.lastPathComponent, "Photo.jpg")
        XCTAssertEqual(plan(name: "Photo.tif", type: .tiff, folder: folder).url?.lastPathComponent, "Photo.tiff")
        XCTAssertEqual(plan(name: "  Scan  ", type: .png, folder: folder).url?.lastPathComponent, "Scan.png")
    }

    func testAnExtensionForAnotherFileTypeIsKeptAsPartOfTheName() {
        XCTAssertEqual(plan(name: "Scan.pdf", type: .png, folder: folder).url?.lastPathComponent, "Scan.pdf.png")
        XCTAssertEqual(plan(name: "v1.2", type: .pdf, folder: folder).url?.lastPathComponent, "v1.2.pdf")
    }

    // MARK: Increment

    func testIncrementsWhenTheNameIsTaken() {
        let plan = plan(folder: folder, existing: ["Scan.pdf"])

        XCTAssertEqual(
            plan,
            .createIncremented(
                folder.appendingPathComponent("Scan 2.pdf"),
                taken: folder.appendingPathComponent("Scan.pdf")
            )
        )
        XCTAssertFalse(plan.isBlocked)
        XCTAssertEqual(plan.caption, "Scan.pdf exists. Will save as Scan 2.pdf")
    }

    func testIncrementSkipsEveryTakenName() {
        let plan = plan(folder: folder, existing: ["Scan.pdf", "Scan 2.pdf", "Scan 3.pdf", "Scan 5.pdf"])

        XCTAssertEqual(plan.url?.lastPathComponent, "Scan 4.pdf")
        XCTAssertEqual(plan.caption, "Scan.pdf exists. Will save as Scan 4.pdf")
    }

    func testOnlyFilesOfTheSameFileTypeCountAsTaken() {
        XCTAssertEqual(
            plan(type: .png, folder: folder, existing: ["Scan.pdf"]),
            .create(folder.appendingPathComponent("Scan.png"))
        )
    }

    func testTakenIncrementedNamesDoNotMatterWhileTheNameItselfIsFree() {
        XCTAssertEqual(
            plan(folder: folder, existing: ["Scan 2.pdf"]),
            .create(folder.appendingPathComponent("Scan.pdf"))
        )
    }

    // MARK: Blocked

    func testBlockedWithoutAFolder() {
        let plan = plan(folder: nil)

        XCTAssertEqual(plan, .blocked(.noFolder))
        XCTAssertTrue(plan.isBlocked)
        XCTAssertNil(plan.url)
        XCTAssertEqual(plan.caption, "Choose a folder to enable Scan.")
    }

    func testBlockedWithAnEmptyName() {
        for name in ["", "   ", ".pdf", " .PDF "] {
            let plan = plan(name: name, folder: folder)
            XCTAssertEqual(plan, .blocked(.emptyName), "name: \"\(name)\"")
            XCTAssertEqual(plan.caption, "Enter a file name.")
        }
    }

    func testBlockedWithASlashOrColonInTheName() {
        for name in ["a/b", "/Scan", "12:30", "Scan:"] {
            let plan = plan(name: name, folder: folder)
            XCTAssertEqual(plan, .blocked(.invalidName), "name: \"\(name)\"")
            XCTAssertTrue(plan.isBlocked)
            XCTAssertEqual(plan.caption, "A file name can't contain / or :")
        }
    }

    func testAMissingFolderIsReportedBeforeAnInvalidName() {
        XCTAssertEqual(plan(name: "", folder: nil), .blocked(.noFolder))
    }

    func testABlockedPlanNeverLooksAtTheDisk() {
        var lookups = 0
        _ = Destination(name: "a/b", fileType: .pdf, folder: folder).plan { _ in lookups += 1; return false }
        _ = Destination(name: "Scan", fileType: .pdf, folder: nil).plan { _ in lookups += 1; return false }
        XCTAssertEqual(lookups, 0)
    }
}
