import XCTest
@testable import Scanimate

/// The pure planning function: what writing to a Destination will do.
final class DestinationPlanTests: XCTestCase {

    private let folder = URL(fileURLWithPath: "/nonexistent-scanimate-tests/Scans", isDirectory: true)

    private func plan(
        name: String = "Scan",
        type: FileType = .pdf,
        folder: URL?,
        append: Bool = false,
        existing: Set<String> = [],
        appendTargets: [String: PDFAppendTarget] = [:]
    ) -> DestinationPlan {
        Destination(name: name, fileType: type, folder: folder, append: append).plan(
            fileExists: { existing.contains($0.lastPathComponent) },
            appendTarget: { appendTargets[$0.lastPathComponent] ?? .unusable }
        )
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
        for destination in [
            Destination(name: "a/b", fileType: .pdf, folder: folder, append: true),
            Destination(name: "Scan", fileType: .pdf, folder: nil, append: true)
        ] {
            _ = destination.plan(
                fileExists: { _ in lookups += 1; return false },
                appendTarget: { _ in lookups += 1; return .unusable }
            )
        }
        XCTAssertEqual(lookups, 0)
    }

    // MARK: Append

    private var scanPDF: URL { folder.appendingPathComponent("Scan.pdf") }

    func testAppendToAMissingFileCreatesIt() {
        let plan = plan(folder: folder, append: true)

        XCTAssertEqual(plan, .createForAppend(scanPDF))
        XCTAssertEqual(plan.url, scanPDF)
        XCTAssertTrue(plan.isAppend)
        XCTAssertFalse(plan.isBlocked)
        XCTAssertEqual(plan.caption, "Scan.pdf doesn't exist yet. Will create it")
    }

    func testAppendToAReadablePDFAddsToItWithoutIncrementing() {
        let plan = plan(
            folder: folder, append: true,
            existing: ["Scan.pdf"], appendTargets: ["Scan.pdf": .appendable(pageCount: 3)]
        )

        XCTAssertEqual(plan, .append(scanPDF, existingPageCount: 3))
        XCTAssertEqual(plan.url, scanPDF)
        XCTAssertTrue(plan.isAppend)
        XCTAssertFalse(plan.isBlocked)
        XCTAssertEqual(plan.caption, "Will add to Scan.pdf (3 pages)")
    }

    func testAppendCaptionCountsASinglePageInTheSingular() {
        let plan = plan(
            folder: folder, append: true,
            existing: ["Scan.pdf"], appendTargets: ["Scan.pdf": .appendable(pageCount: 1)]
        )
        XCTAssertEqual(plan.caption, "Will add to Scan.pdf (1 page)")
    }

    func testAppendToAProtectedPDFIsBlocked() {
        let plan = plan(
            folder: folder, append: true,
            existing: ["Scan.pdf"], appendTargets: ["Scan.pdf": .protected]
        )

        XCTAssertEqual(plan, .blocked(.appendTargetProtected(scanPDF)))
        XCTAssertTrue(plan.isBlocked)
        XCTAssertNil(plan.url)
        XCTAssertEqual(plan.caption, "Scan.pdf is protected and can't be added to")
    }

    func testAppendToAFileThatIsNotAUsablePDFIsBlocked() {
        let plan = plan(
            folder: folder, append: true,
            existing: ["Scan.pdf"], appendTargets: ["Scan.pdf": .unusable]
        )

        XCTAssertEqual(plan, .blocked(.appendTargetUnusable(scanPDF)))
        XCTAssertTrue(plan.isBlocked)
        XCTAssertNil(plan.url)
        XCTAssertEqual(plan.caption, "Scan.pdf can't be opened as a PDF")
    }

    func testAppendIsIgnoredForFileTypesThatAreNotPDF() {
        for type in [FileType.png, .jpeg, .tiff] {
            let name = "Scan.\(type.fileExtension)"
            var askedAboutAppending = false
            let destination = Destination(name: "Scan", fileType: type, folder: folder, append: true)
            XCTAssertFalse(destination.appendsToPDF)

            let taken = destination.plan(
                fileExists: { $0.lastPathComponent == name },
                appendTarget: { _ in askedAboutAppending = true; return .appendable(pageCount: 1) }
            )

            XCTAssertEqual(taken.caption, "\(name) exists. Will save as Scan 2.\(type.fileExtension)")
            XCTAssertFalse(taken.isAppend)
            XCTAssertFalse(askedAboutAppending)
            XCTAssertEqual(plan(type: type, folder: folder, append: true).caption, "Will create \(name)")
        }
    }

    func testWithoutAppendAnExistingPDFIsIncrementedAndNeverInspected() {
        var askedAboutAppending = false
        let plan = Destination(name: "Scan", fileType: .pdf, folder: folder).plan(
            fileExists: { $0.lastPathComponent == "Scan.pdf" },
            appendTarget: { _ in askedAboutAppending = true; return .appendable(pageCount: 3) }
        )

        XCTAssertEqual(plan.caption, "Scan.pdf exists. Will save as Scan 2.pdf")
        XCTAssertFalse(plan.isAppend)
        XCTAssertFalse(askedAboutAppending)
    }

    func testAnInvalidNameIsReportedBeforeTheAppendTarget() {
        XCTAssertEqual(plan(name: "a/b", folder: folder, append: true), .blocked(.invalidName))
        XCTAssertEqual(plan(name: "", folder: folder, append: true), .blocked(.emptyName))
        XCTAssertEqual(plan(folder: nil, append: true), .blocked(.noFolder))
    }
}
