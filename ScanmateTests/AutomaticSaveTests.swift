import PDFKit
import XCTest
@testable import Scanimate

/// The Destination on `ScanViewModel`: gating Scan, and writing the ScanResult
/// automatically the moment a ScanJob completes.
@MainActor
final class AutomaticSaveTests: XCTestCase {

    private let host = "192.168.1.66"
    private let folder = URL(fileURLWithPath: "/nonexistent-scanimate-tests/Scans", isDirectory: true)
    private let region = ScanRegion(xOffset: 0, yOffset: 0, width: 8500, height: 11000)

    // MARK: Automatic save

    func testCompletedPlatenScanWritesExactlyOnceWithNoSaveAction() async throws {
        let page = try makeTestJPEG(width: 40, height: 30)
        let writer = InMemoryDestinationWriter(folders: [folder])
        let vm = makeVM(pages: [page], writer: writer)
        vm.resolution = .dpi300
        XCTAssertEqual(vm.destinationCaption, "Will create Scan.png")

        vm.startScan()
        try await waitForCondition { vm.isScanComplete }

        let url = folder.appendingPathComponent("Scan.png")
        XCTAssertEqual(
            writer.writes,
            [.init(pages: [page], dpi: 300, url: url, fileType: .png, append: false)]
        )
        XCTAssertEqual(Array(writer.files.keys), [url.path])
        XCTAssertEqual(try describeTestImage(try XCTUnwrap(writer.files[url.path])).type, "public.png")

        XCTAssertEqual(vm.saveStatus, .saved(fileName: "Scan.png", folderName: "Scans"))
        XCTAssertEqual(vm.statusMessage, "Saved Scan.png to Scans")
        XCTAssertNil(vm.alertError)
        XCTAssertEqual(vm.previewPages, [page], "The result stays on screen after the save")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "The fake must not touch the filesystem")
    }

    func testCompletedADFScanWritesOneMultiPagePDF() async throws {
        let pages = [
            try makeTestJPEG(width: 40, height: 30),
            try makeTestJPEG(width: 30, height: 40),
            try makeTestJPEG(width: 50, height: 50)
        ]
        let writer = InMemoryDestinationWriter(folders: [folder])
        let vm = makeVM(pages: pages, writer: writer)
        vm.inputSource = .adf
        vm.destinationName = "Contract"

        vm.startScan()
        try await waitForCondition { vm.isScanComplete }

        let url = folder.appendingPathComponent("Contract.pdf")
        XCTAssertEqual(
            writer.writes,
            [.init(pages: pages, dpi: 300, url: url, fileType: .pdf, append: false)]
        )
        XCTAssertEqual(writer.pdfPageCount(at: url), 3)
        XCTAssertEqual(vm.statusMessage, "Saved Contract.pdf to Scans")
    }

    func testJPEGDestinationWritesTheScannersRawPageData() async throws {
        let page = try makeTestJPEG(width: 40, height: 30)
        let writer = InMemoryDestinationWriter(folders: [folder])
        let vm = makeVM(pages: [page], writer: writer)
        vm.platenFileType = .jpeg

        vm.startScan()
        try await waitForCondition { vm.isScanComplete }

        let url = folder.appendingPathComponent("Scan.jpg")
        XCTAssertEqual(writer.writes.map(\.fileType), [.jpeg])
        XCTAssertEqual(writer.files[url.path], page)
    }

    func testOverviewWritesNothing() async throws {
        let writer = InMemoryDestinationWriter(folders: [folder])
        let vm = makeVM(pages: [try makeTestJPEG(width: 8, height: 8)], writer: writer)

        vm.startOverview()
        try await waitForCondition { !vm.isOverviewing && vm.overviewImage != nil }

        XCTAssertTrue(writer.writes.isEmpty)
        XCTAssertTrue(writer.files.isEmpty)
        XCTAssertNil(vm.saveStatus)
    }

    func testFailedOrCancelledScanJobWritesNothing() async throws {
        let writer = InMemoryDestinationWriter(folders: [folder])
        let mock = MockScanner(states: [], result: .failure(ScanError.noDocument))
        let vm = makeVM(mock: mock, writer: writer)

        vm.startScan()
        try await waitForCondition { vm.alertError != nil }

        XCTAssertTrue(writer.writes.isEmpty)
        XCTAssertNil(vm.saveStatus)
    }

    // MARK: Auto-increment

    func testExistingFileIsIncrementedNotOverwritten() async throws {
        let page = try makeTestJPEG(width: 8, height: 8)
        let earlier = Data("an earlier scan".utf8)
        let taken = folder.appendingPathComponent("Scan.pdf")
        let writer = InMemoryDestinationWriter(files: [taken: earlier], folders: [folder])
        let vm = makeVM(pages: [page], writer: writer)
        vm.platenFileType = .pdf
        XCTAssertEqual(vm.destinationCaption, "Scan.pdf exists. Will save as Scan 2.pdf")

        vm.startScan()
        try await waitForCondition { vm.isScanComplete }

        XCTAssertEqual(writer.writes.map(\.url), [folder.appendingPathComponent("Scan 2.pdf")])
        XCTAssertEqual(writer.files[taken.path], earlier, "The existing file is untouched")
        XCTAssertEqual(vm.statusMessage, "Saved Scan 2.pdf to Scans")
    }

    func testRepeatedScansNeverReuseAName() async throws {
        let writer = InMemoryDestinationWriter(folders: [folder])
        let vm = makeVM(pages: [try makeTestJPEG(width: 8, height: 8)], writer: writer)

        for expected in ["Scan.png", "Scan 2.png", "Scan 3.png"] {
            XCTAssertTrue(vm.canScan, "Scan stays available so the next page is one click")
            vm.startScan()
            try await waitForCondition { vm.saveStatus != nil }
            XCTAssertEqual(vm.statusMessage, "Saved \(expected) to Scans")
        }

        XCTAssertEqual(writer.writes.map(\.url.lastPathComponent), ["Scan.png", "Scan 2.png", "Scan 3.png"])
        XCTAssertEqual(vm.destinationCaption, "Scan.png exists. Will save as Scan 4.png",
                       "The caption is recomputed after each save")
    }

    func testPlanIsRecomputedAtWriteTimeNotTakenFromTheCaption() async throws {
        actor GatedScanner: WSDScannerProtocol {
            private let pages: [Data]
            private var gate: CheckedContinuation<Void, Never>?
            init(pages: [Data]) { self.pages = pages }
            func scan(ticket: ScanTicket, onState: @Sendable (ScanJob) async -> Void) async throws -> [Data] {
                await onState(.retrievingPage(1))
                await withCheckedContinuation { gate = $0 }
                return pages
            }
            func overview() async throws -> Data { Data() }
            var isWaiting: Bool { gate != nil }
            func finish() { gate?.resume(); gate = nil }
        }

        let page = try makeTestJPEG(width: 8, height: 8)
        let scanner = GatedScanner(pages: [page])
        let writer = InMemoryDestinationWriter(folders: [folder])
        let vm = ScanViewModel(
            scannerFactory: { _ in scanner },
            discoveryFactory: { MockDiscovery() },
            destinationWriter: writer,
            defaults: makeIsolatedDefaults()
        )
        vm.selectedTarget = nil
        vm.manualHost = host
        vm.selectedRegion = region
        vm.destinationFolder = folder
        XCTAssertEqual(vm.destinationCaption, "Will create Scan.png")

        vm.startScan()
        while await !scanner.isWaiting { try await Task.sleep(nanoseconds: 5_000_000) }
        // Another app creates Scan.png while the Scanner is still working.
        try writer.write(pages: [page], dpi: 300, to: folder.appendingPathComponent("Scan.png"), as: .png, append: false)
        await scanner.finish()
        try await waitForCondition { vm.saveStatus != nil }

        XCTAssertEqual(vm.statusMessage, "Saved Scan 2.png to Scans")
        XCTAssertEqual(writer.writes.map(\.url.lastPathComponent), ["Scan.png", "Scan 2.png"])
    }

    func testRefreshPicksUpFilesThatAppearedBehindTheAppsBack() throws {
        let page = try makeTestJPEG(width: 8, height: 8)
        let writer = InMemoryDestinationWriter(folders: [folder])
        let vm = makeVM(pages: [page], writer: writer)
        XCTAssertEqual(vm.destinationCaption, "Will create Scan.png")

        try writer.write(pages: [page], dpi: 300, to: folder.appendingPathComponent("Scan.png"), as: .png, append: false)
        XCTAssertEqual(vm.destinationCaption, "Will create Scan.png", "Stale until refreshed")

        // What the view does on NSApplication.didBecomeActiveNotification.
        vm.refreshDestinationPlan()
        XCTAssertEqual(vm.destinationCaption, "Scan.png exists. Will save as Scan 2.png")
    }

    // MARK: ADF forces PDF

    func testADFForcesPDFAndThePlatenChoiceReturns() {
        let vm = makeVM(pages: [], writer: InMemoryDestinationWriter(folders: [folder]))
        XCTAssertEqual(vm.fileType, .png, "PNG is the default for the Platen")
        XCTAssertFalse(vm.isFileTypeForced)

        vm.platenFileType = .tiff
        XCTAssertEqual(vm.destinationCaption, "Will create Scan.tiff")

        vm.inputSource = .adf
        XCTAssertTrue(vm.isFileTypeForced)
        XCTAssertEqual(vm.fileType, .pdf)
        XCTAssertEqual(vm.destination.fileType, .pdf)
        XCTAssertEqual(vm.destinationCaption, "Will create Scan.pdf")

        vm.inputSource = .flatbed
        XCTAssertFalse(vm.isFileTypeForced)
        XCTAssertEqual(vm.fileType, .tiff)
        XCTAssertEqual(vm.destinationCaption, "Will create Scan.tiff")
    }

    func testMultiPageADFScanIsWrittenAsPDFWhateverThePlatenChoice() async throws {
        let pages = [try makeTestJPEG(width: 40, height: 30), try makeTestJPEG(width: 30, height: 40)]
        let writer = InMemoryDestinationWriter(folders: [folder])
        let vm = makeVM(pages: pages, writer: writer)
        vm.platenFileType = .png
        vm.inputSource = .adf

        vm.startScan()
        try await waitForCondition { vm.isScanComplete }

        XCTAssertEqual(writer.writes.map(\.fileType), [.pdf])
        XCTAssertEqual(writer.pdfPageCount(at: folder.appendingPathComponent("Scan.pdf")), 2,
                       "No page is silently dropped")
        XCTAssertEqual(vm.platenFileType, .png, "The Platen choice is remembered")
    }

    // MARK: canScan gate

    func testCanScanFalseUntilAFolderIsChosen() {
        let vm = makeVM(pages: [], writer: InMemoryDestinationWriter(folders: [folder]))
        vm.destinationFolder = nil

        XCTAssertFalse(vm.canScan)
        XCTAssertEqual(vm.destinationPlan, .blocked(.noFolder))
        XCTAssertEqual(vm.destinationCaption, "Choose a folder to enable Scan.")

        vm.destinationFolder = folder
        XCTAssertTrue(vm.canScan)
        XCTAssertEqual(vm.destinationCaption, "Will create Scan.png")
    }

    func testCanScanFalseWithAnInvalidName() {
        let vm = makeVM(pages: [], writer: InMemoryDestinationWriter(folders: [folder]))

        vm.destinationName = ""
        XCTAssertFalse(vm.canScan)
        XCTAssertEqual(vm.destinationCaption, "Enter a file name.")

        for name in ["a/b", "12:30"] {
            vm.destinationName = name
            XCTAssertFalse(vm.canScan, name)
            XCTAssertEqual(vm.destinationPlan, .blocked(.invalidName))
        }

        vm.destinationName = "Receipt"
        XCTAssertTrue(vm.canScan)
        XCTAssertEqual(vm.destinationCaption, "Will create Receipt.png")
    }

    func testStartScanCreatesNoScanJobWithAnInvalidDestination() async throws {
        let mock = MockScanner(states: [.checkingScanner], result: .success([Fixtures.minimalJPEG]))
        let writer = InMemoryDestinationWriter(folders: [folder])
        let vm = makeVM(mock: mock, writer: writer)
        vm.destinationFolder = nil

        vm.startScan()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(vm.scanTask)
        XCTAssertNil(vm.jobState)
        let captured = await mock.capturedTicket
        XCTAssertNil(captured, "No ScanTicket should reach the Scanner")
        XCTAssertTrue(writer.writes.isEmpty)
    }

    // MARK: Failed write and retry

    func testFailedWriteKeepsThePagesAndARetrySucceeds() async throws {
        let page = try makeTestJPEG(width: 8, height: 8)
        let writer = InMemoryDestinationWriter(
            folders: [folder],
            writeError: ScanError.protocolError("disk full")
        )
        let vm = makeVM(pages: [page], writer: writer)

        vm.startScan()
        try await waitForCondition { vm.saveStatus != nil }

        guard case .failed(let reason)? = vm.saveStatus else {
            return XCTFail("Expected a failed save, got \(String(describing: vm.saveStatus))")
        }
        XCTAssertTrue(reason.contains("disk full"), reason)
        XCTAssertTrue(vm.statusMessage.hasPrefix("Not saved."), vm.statusMessage)
        XCTAssertTrue(vm.isScanComplete)
        XCTAssertEqual(vm.previewPages, [page], "The pages stay in memory")
        XCTAssertTrue(writer.files.isEmpty)
        XCTAssertEqual(vm.destinationFolder, folder, "The folder is still there, so it is kept")

        writer.failWrites(with: nil)
        vm.retrySave()

        let url = folder.appendingPathComponent("Scan.png")
        XCTAssertEqual(writer.writes, [.init(pages: [page], dpi: 300, url: url, fileType: .png, append: false)])
        XCTAssertEqual(vm.saveStatus, .saved(fileName: "Scan.png", folderName: "Scans"))

        // Nothing left to retry: a second press writes nothing more.
        vm.retrySave()
        XCTAssertEqual(writer.writes.count, 1)
    }

    func testWriteIntoAVanishedFolderClearsTheFolderAndRetryUsesTheNewOne() async throws {
        let page = try makeTestJPEG(width: 8, height: 8)
        let writer = InMemoryDestinationWriter(folders: [folder])
        let vm = makeVM(pages: [page], writer: writer)
        writer.removeFolder(folder)

        vm.startScan()
        try await waitForCondition { vm.saveStatus != nil }

        guard case .failed = vm.saveStatus else {
            return XCTFail("Expected a failed save, got \(String(describing: vm.saveStatus))")
        }
        XCTAssertNil(vm.destinationFolder)
        XCTAssertEqual(vm.destinationCaption, "Choose a folder to enable Scan.")
        XCTAssertFalse(vm.canScan)
        XCTAssertEqual(vm.previewPages, [page])

        // Retrying before choosing a folder still cannot write, and keeps the pages.
        vm.retrySave()
        XCTAssertTrue(writer.writes.isEmpty)
        XCTAssertEqual(vm.previewPages, [page])

        // The user chooses another folder, then retries.
        let other = URL(fileURLWithPath: "/nonexistent-scanimate-tests/Other", isDirectory: true)
        writer.addFolder(other)
        vm.destinationFolder = other
        vm.retrySave()

        XCTAssertEqual(writer.writes.map(\.url), [other.appendingPathComponent("Scan.png")])
        XCTAssertEqual(vm.saveStatus, .saved(fileName: "Scan.png", folderName: "Other"))
    }

    // MARK: Result lifetime

    func testOverviewClearsThePreviousResult() async throws {
        let writer = InMemoryDestinationWriter(folders: [folder])
        let vm = makeVM(pages: [try makeTestJPEG(width: 8, height: 8)], writer: writer)
        vm.startScan()
        try await waitForCondition { vm.isScanComplete }
        XCTAssertNotNil(vm.saveStatus)

        vm.startOverview()

        XCTAssertFalse(vm.isScanComplete)
        XCTAssertTrue(vm.previewPages.isEmpty)
        XCTAssertNil(vm.saveStatus)
        try await waitForCondition { !vm.isOverviewing }
        XCTAssertEqual(writer.writes.count, 1)
    }

    // MARK: Persistence

    func testNameAndFileTypePersistButTheFolderDoesNot() {
        let defaults = makeIsolatedDefaults()
        let writer = InMemoryDestinationWriter(folders: [folder])
        func launch() -> ScanViewModel {
            ScanViewModel(
                scannerFactory: { _ in MockScanner(states: [], result: .success([])) },
                discoveryFactory: { MockDiscovery() },
                destinationWriter: writer,
                defaults: defaults
            )
        }

        let first = launch()
        XCTAssertEqual(first.destinationName, "Scan", "The default name")
        XCTAssertEqual(first.platenFileType, .png, "The default file type for the Platen")
        XCTAssertNil(first.destinationFolder)
        first.destinationName = "Receipt"
        first.platenFileType = .jpeg
        first.destinationFolder = folder

        let relaunched = launch()
        XCTAssertEqual(relaunched.destinationName, "Receipt")
        XCTAssertEqual(relaunched.platenFileType, .jpeg)
        XCTAssertNil(relaunched.destinationFolder, "The folder is chosen again on every launch")
        XCTAssertFalse(relaunched.canScan)
        XCTAssertEqual(relaunched.destinationCaption, "Choose a folder to enable Scan.")

        let stored = defaults.dictionaryRepresentation().values.compactMap { $0 as? String }
        XCTAssertFalse(stored.contains { $0.contains("nonexistent-scanimate-tests") }, "No folder path in UserDefaults")
    }

    // MARK: - Helpers

    private func makeVM(pages: [Data], writer: InMemoryDestinationWriter) -> ScanViewModel {
        makeVM(mock: MockScanner(states: [.checkingScanner], result: .success(pages)), writer: writer)
    }

    /// A view model ready to scan from the Platen into `folder`.
    private func makeVM(mock: MockScanner, writer: InMemoryDestinationWriter) -> ScanViewModel {
        let vm = ScanViewModel(
            scannerFactory: { _ in mock },
            discoveryFactory: { MockDiscovery() },
            destinationWriter: writer,
            defaults: makeIsolatedDefaults()
        )
        vm.selectedTarget = nil
        vm.manualHost = host
        vm.selectedRegion = region
        vm.inputSource = .flatbed
        vm.destinationFolder = folder
        return vm
    }

    private func waitForCondition(timeout: TimeInterval = 2, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
