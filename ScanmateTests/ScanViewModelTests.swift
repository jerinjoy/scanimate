import PDFKit
import XCTest
@testable import Scanimate

// MARK: - Mock scanner

actor MockScanner: WSDScannerProtocol {
    let stateSequence: [ScanJob]
    let finalResult: Result<[Data], Error>
    let overviewResult: Result<Data, Error>
    private(set) var capturedTicket: ScanTicket?

    init(
        states: [ScanJob],
        result: Result<[Data], Error>,
        overviewResult: Result<Data, Error> = .success(Fixtures.minimalJPEG)
    ) {
        self.stateSequence = states
        self.finalResult = result
        self.overviewResult = overviewResult
    }

    func scan(
        ticket: ScanTicket,
        onState: @Sendable (ScanJob) async -> Void
    ) async throws -> [Data] {
        capturedTicket = ticket
        for state in stateSequence {
            try Task.checkCancellation()
            await onState(state)
        }
        return try finalResult.get()
    }

    func overview() async throws -> Data {
        return try overviewResult.get()
    }
}

// MARK: - Mock discovery

actor MockDiscovery: ScannerDiscoveryProtocol {
    private let canned: [ScannerTarget]

    init(targets: [ScannerTarget] = []) {
        self.canned = targets
    }

    func start(onFound: @escaping @Sendable (ScannerTarget) -> Void) async {
        for target in canned {
            onFound(target)
        }
    }

    func stop() async {}
}

// MARK: - Helpers

@MainActor
private func makeVM(
    mock: MockScanner,
    discoveryTargets: [ScannerTarget] = []
) -> ScanViewModel {
    let vm = ScanViewModel(
        scannerFactory: { _ in mock },
        discoveryFactory: { MockDiscovery(targets: discoveryTargets) },
        destinationWriter: InMemoryDestinationWriter(folders: [defaultTestFolder]),
        defaults: makeIsolatedDefaults()
    )
    // A Platen ScanJob needs a ScanRegion, and every ScanJob a valid
    // Destination; give the shared VM both so tests that just start a scan are
    // not blocked by the gate.
    vm.selectedRegion = defaultTestRegion
    vm.destinationFolder = defaultTestFolder
    return vm
}

private let defaultTestRegion = ScanRegion(xOffset: 0, yOffset: 0, width: 8500, height: 11000)
private let defaultTestFolder = URL(fileURLWithPath: "/nonexistent-scanimate-tests/Scans", isDirectory: true)

// MARK: - Tests

@MainActor
final class ScanViewModelTests: XCTestCase {

    func testHappyPathSetsCompleteState() async throws {
        let jpeg = Fixtures.minimalJPEG
        let mock = MockScanner(
            states: [.checkingScanner, .creatingJob(attempt: 1), .retrievingPage(1)],
            result: .success([jpeg])
        )
        let vm = makeVM(mock: mock)
        vm.manualHost = "192.168.1.66"

        vm.startScan()

        try await waitForCondition(timeout: 2) { vm.isScanComplete }

        if case .complete(let pages) = vm.jobState {
            XCTAssertEqual(pages.count, 1)
        } else {
            XCTFail("Expected complete state, got \(String(describing: vm.jobState))")
        }
        XCTAssertNil(vm.alertError)
        XCTAssertFalse(vm.isScanning)
    }

    func testProgressMessageDuringScanning() async throws {
        let mock = MockScanner(
            states: [.checkingScanner, .creatingJob(attempt: 1), .retrievingPage(1)],
            result: .success([try makeTestJPEG(width: 8, height: 8)])
        )
        let vm = makeVM(mock: mock)
        vm.manualHost = "192.168.1.66"
        vm.startScan()

        try await waitForCondition(timeout: 2) { vm.isScanComplete }

        XCTAssertEqual(vm.statusMessage, "Saved Scan.png to Scans")
    }

    func testCancelButtonHidesAfterCompletion() async throws {
        let mock = MockScanner(
            states: [.checkingScanner],
            result: .success([Fixtures.minimalJPEG])
        )
        let vm = makeVM(mock: mock)
        vm.manualHost = "192.168.1.66"
        vm.startScan()

        try await waitForCondition(timeout: 2) { !vm.isScanning }
        XCTAssertFalse(vm.isScanning, "isScanning should be false after completion")
    }

    func testUnreachableErrorSetsAlert() async throws {
        let mock = MockScanner(states: [], result: .failure(ScanError.unreachable(host: "192.168.1.66")))
        let vm = makeVM(mock: mock)
        vm.manualHost = "192.168.1.66"

        vm.startScan()
        try await waitForCondition(timeout: 2) { vm.alertError != nil }

        XCTAssertEqual(vm.alertError, ScanError.unreachable(host: "192.168.1.66"))
        XCTAssertEqual(
            vm.alertError?.errorDescription,
            "Cannot reach 192.168.1.66 — is the printer on and connected to the network?"
        )
    }

    func testNoDocumentErrorSetsAlert() async throws {
        let mock = MockScanner(states: [], result: .failure(ScanError.noDocument))
        let vm = makeVM(mock: mock)
        vm.manualHost = "192.168.1.66"

        vm.startScan()
        try await waitForCondition(timeout: 2) { vm.alertError != nil }

        XCTAssertEqual(vm.alertError, ScanError.noDocument)
        XCTAssertEqual(
            vm.alertError?.errorDescription,
            "No document detected — place a page on the glass or load the ADF and try again."
        )
    }

    func testPrinterBusyErrorSetsAlert() async throws {
        let mock = MockScanner(states: [], result: .failure(ScanError.printerBusy))
        let vm = makeVM(mock: mock)
        vm.manualHost = "192.168.1.66"

        vm.startScan()
        try await waitForCondition(timeout: 2) { vm.alertError != nil }

        XCTAssertEqual(vm.alertError, ScanError.printerBusy)
        XCTAssertEqual(vm.alertError?.errorDescription, "The printer is busy — try again in a moment.")
    }

    func testProtocolErrorSetsAlert() async throws {
        let mock = MockScanner(states: [], result: .failure(ScanError.protocolError("unexpected XML")))
        let vm = makeVM(mock: mock)
        vm.manualHost = "192.168.1.66"

        vm.startScan()
        try await waitForCondition(timeout: 2) { vm.alertError != nil }

        if case .protocolError(let detail) = vm.alertError {
            XCTAssertTrue(detail.contains("unexpected XML"))
        } else {
            XCTFail("Expected protocolError")
        }
    }

    func testCancelSetsJobStateCancelled() async throws {
        actor BlockingScanner: WSDScannerProtocol {
            func scan(ticket: ScanTicket, onState: @Sendable (ScanJob) async -> Void) async throws -> [Data] {
                await onState(.checkingScanner)
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return []
            }
            func overview() async throws -> Data { Data() }
        }

        let vm = ScanViewModel(
            scannerFactory: { _ in BlockingScanner() },
            destinationWriter: InMemoryDestinationWriter(folders: [defaultTestFolder]),
            defaults: makeIsolatedDefaults()
        )
        vm.manualHost = "192.168.1.66"
        vm.selectedRegion = defaultTestRegion
        vm.destinationFolder = defaultTestFolder

        vm.startScan()
        try await waitForCondition(timeout: 1) { vm.isScanning }
        vm.cancelScan()
        try await waitForCondition(timeout: 2) { !vm.isScanning }
        XCTAssertFalse(vm.isScanning)
    }

    func testResetForNextScanClearsState() async throws {
        let mock = MockScanner(states: [], result: .success([Fixtures.minimalJPEG]))
        let vm = makeVM(mock: mock)
        vm.manualHost = "192.168.1.66"

        vm.startScan()
        try await waitForCondition(timeout: 2) { vm.isScanComplete }

        vm.resetForNextScan()

        XCTAssertNil(vm.jobState)
        XCTAssertTrue(vm.previewPages.isEmpty)
        XCTAssertNil(vm.alertError)
        XCTAssertFalse(vm.isScanning)
        XCTAssertFalse(vm.isScanComplete)
    }

    // MARK: - Overview tests

    func testStartOverviewSetsIsOverviewing() async throws {
        actor DelayedOverviewScanner: WSDScannerProtocol {
            func scan(ticket: ScanTicket, onState: @Sendable (ScanJob) async -> Void) async throws -> [Data] { [] }
            func overview() async throws -> Data {
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return Data()
            }
        }

        let vm = ScanViewModel(scannerFactory: { _ in DelayedOverviewScanner() })
        vm.manualHost = "192.168.1.66"

        vm.startOverview()
        try await waitForCondition(timeout: 1) { vm.isOverviewing }
        XCTAssertTrue(vm.isOverviewing)

        vm.overviewTask?.cancel()
        try await waitForCondition(timeout: 2) { !vm.isOverviewing }
        XCTAssertFalse(vm.isOverviewing)
    }

    func testStartOverviewPopulatesOverviewImage() async throws {
        let jpeg = Fixtures.minimalJPEG
        let mock = MockScanner(
            states: [],
            result: .success([]),
            overviewResult: .success(jpeg)
        )
        let vm = makeVM(mock: mock)
        vm.manualHost = "192.168.1.66"

        vm.startOverview()
        try await waitForCondition(timeout: 2) { !vm.isOverviewing && vm.overviewImage != nil }

        XCTAssertEqual(vm.overviewImage, jpeg)
        XCTAssertFalse(vm.isOverviewing)
    }

    func testStartOverviewPreservesSelectedRegion() async throws {
        let mock = MockScanner(
            states: [],
            result: .success([Fixtures.minimalJPEG]),
            overviewResult: .success(Fixtures.minimalJPEG)
        )
        let vm = makeVM(mock: mock)
        vm.manualHost = "192.168.1.66"

        // First Overview, then the user drags a ScanRegion on its preview.
        vm.startOverview()
        try await waitForCondition(timeout: 2) { !vm.isOverviewing && vm.overviewImage != nil }
        let region = ScanRegion(xOffset: 100, yOffset: 100, width: 5000, height: 5000)
        vm.selectedRegion = region

        // Running Overview again keeps the ScanRegion, both while it runs and after.
        vm.startOverview()
        XCTAssertEqual(vm.selectedRegion, region)
        try await waitForCondition(timeout: 2) { !vm.isOverviewing && vm.overviewImage != nil }
        XCTAssertEqual(vm.selectedRegion, region)

        // The next ScanJob still reads from that ScanRegion.
        vm.startScan()
        try await waitForCondition(timeout: 2) { vm.isScanComplete }
        let captured = await mock.capturedTicket
        XCTAssertEqual(captured?.scanRegion, region)
    }

    func testStartScanPassesSelectedRegionToTicket() async throws {
        let mock = MockScanner(states: [], result: .success([Fixtures.minimalJPEG]))
        let vm = makeVM(mock: mock)
        vm.manualHost = "192.168.1.66"

        let region = ScanRegion(xOffset: 1000, yOffset: 2000, width: 5000, height: 6000)
        vm.selectedRegion = region

        vm.startScan()
        try await waitForCondition(timeout: 2) { vm.isScanComplete }

        let captured = await mock.capturedTicket
        XCTAssertEqual(captured?.scanRegion, region)
    }

    // MARK: - canScan gate

    func testCanScanFalseForPlatenWithoutScanRegion() {
        let vm = makeVM(mock: MockScanner(states: [], result: .success([])))
        vm.manualHost = "192.168.1.66"
        vm.inputSource = .flatbed
        vm.selectedRegion = nil

        XCTAssertFalse(vm.canScan)
    }

    func testCanScanTrueForPlatenWithScanRegion() {
        let vm = makeVM(mock: MockScanner(states: [], result: .success([])))
        vm.manualHost = "192.168.1.66"
        vm.inputSource = .flatbed
        vm.selectedRegion = ScanRegion(xOffset: 1000, yOffset: 1000, width: 2000, height: 3000)

        XCTAssertTrue(vm.canScan)
    }

    func testCanScanTrueForADFWithoutScanRegion() {
        let vm = makeVM(mock: MockScanner(states: [], result: .success([])))
        vm.manualHost = "192.168.1.66"
        vm.inputSource = .adf
        vm.selectedRegion = nil

        XCTAssertTrue(vm.canScan)
    }

    func testCanScanFalseWithoutHost() {
        let vm = makeVM(mock: MockScanner(states: [], result: .success([])))
        vm.selectedTarget = nil
        vm.manualHost = ""

        XCTAssertFalse(vm.canScan)
    }

    func testStartScanCreatesNoScanJobWhenCanScanIsFalse() async throws {
        let mock = MockScanner(states: [.checkingScanner], result: .success([Fixtures.minimalJPEG]))
        let vm = makeVM(mock: mock)
        vm.manualHost = "192.168.1.66"
        vm.inputSource = .flatbed
        vm.selectedRegion = nil

        vm.startScan()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(vm.scanTask)
        XCTAssertNil(vm.jobState)
        let captured = await mock.capturedTicket
        XCTAssertNil(captured, "No ScanTicket should reach the Scanner")
    }

    func testADFTicketCarriesNoScanRegion() async throws {
        let mock = MockScanner(states: [], result: .success([Fixtures.minimalJPEG]))
        let vm = makeVM(mock: mock)
        vm.manualHost = "192.168.1.66"
        // A ScanRegion drawn for the Platen before switching the source to ADF.
        vm.selectedRegion = ScanRegion(xOffset: 1000, yOffset: 2000, width: 5000, height: 6000)
        vm.inputSource = .adf

        vm.startScan()
        try await waitForCondition(timeout: 2) { vm.isScanComplete }

        let captured = await mock.capturedTicket
        XCTAssertEqual(captured?.source, .adf)
        XCTAssertNil(captured?.scanRegion)
    }

    func testOverviewErrorSetsAlertError() async throws {
        let mock = MockScanner(
            states: [],
            result: .success([]),
            overviewResult: .failure(ScanError.unreachable(host: "192.168.1.66"))
        )
        let vm = makeVM(mock: mock)
        vm.manualHost = "192.168.1.66"

        vm.startOverview()
        try await waitForCondition(timeout: 2) { vm.alertError != nil }

        XCTAssertEqual(vm.alertError, ScanError.unreachable(host: "192.168.1.66"))
        XCTAssertFalse(vm.isOverviewing)
    }

    // MARK: - Append to existing PDF

    private var scanPDF: URL { defaultTestFolder.appendingPathComponent("Scan.pdf") }

    /// A view model ready to scan `pages` from the Platen as PDF into the test folder.
    private func makeAppendVM(pages: [Data], writer: InMemoryDestinationWriter) -> ScanViewModel {
        let mock = MockScanner(states: [.checkingScanner], result: .success(pages))
        let vm = ScanViewModel(
            scannerFactory: { _ in mock },
            discoveryFactory: { MockDiscovery() },
            destinationWriter: writer,
            defaults: makeIsolatedDefaults()
        )
        vm.selectedTarget = nil
        vm.manualHost = "192.168.1.66"
        vm.selectedRegion = defaultTestRegion
        vm.inputSource = .flatbed
        vm.platenFileType = .pdf
        vm.destinationFolder = defaultTestFolder
        return vm
    }

    private func makePDF(pageCount: Int) throws -> Data {
        let pages = try (0..<pageCount).map { _ in try makeTestJPEG(width: 30, height: 40) }
        return try FileDestinationWriter.encode(pages: pages, dpi: 300, as: .pdf)
    }

    func testAppendWithExistingFilePassesAppendTrueToTheSameURL() async throws {
        let page = try makeTestJPEG(width: 40, height: 30)
        let writer = InMemoryDestinationWriter(files: [scanPDF: try makePDF(pageCount: 3)], folders: [defaultTestFolder])
        let vm = makeAppendVM(pages: [page], writer: writer)
        vm.appendToExistingPDF = true
        XCTAssertEqual(vm.destinationPlan, .append(scanPDF, existingPageCount: 3))
        XCTAssertEqual(vm.destinationCaption, "Will add to Scan.pdf (3 pages)")
        XCTAssertTrue(vm.canScan)

        vm.startScan()
        try await waitForCondition(timeout: 2) { vm.saveStatus != nil }

        XCTAssertEqual(
            writer.writes,
            [.init(pages: [page], dpi: 300, url: scanPDF, fileType: .pdf, append: true)]
        )
        XCTAssertEqual(Array(writer.files.keys), [scanPDF.path], "No new file, no incremented name")
        XCTAssertEqual(writer.pdfPageCount(at: scanPDF), 4)
        XCTAssertEqual(vm.saveStatus, .appended(fileName: "Scan.pdf", addedPageCount: 1, totalPageCount: 4))
        XCTAssertEqual(vm.statusMessage, "Added 1 page to Scan.pdf (4 pages)")
        XCTAssertEqual(vm.destinationCaption, "Will add to Scan.pdf (4 pages)", "The caption follows the file")
    }

    func testAppendWithNoFileCreatesIt() async throws {
        let page = try makeTestJPEG(width: 40, height: 30)
        let writer = InMemoryDestinationWriter(folders: [defaultTestFolder])
        let vm = makeAppendVM(pages: [page], writer: writer)
        vm.appendToExistingPDF = true
        XCTAssertEqual(vm.destinationPlan, .createForAppend(scanPDF))
        XCTAssertEqual(vm.destinationCaption, "Scan.pdf doesn't exist yet. Will create it")
        XCTAssertTrue(vm.canScan)

        vm.startScan()
        try await waitForCondition(timeout: 2) { vm.saveStatus != nil }

        XCTAssertEqual(writer.writes.map(\.url), [scanPDF])
        XCTAssertEqual(writer.pdfPageCount(at: scanPDF), 1)
        XCTAssertEqual(vm.saveStatus, .saved(fileName: "Scan.pdf", folderName: "Scans"))
        XCTAssertEqual(vm.statusMessage, "Saved Scan.pdf to Scans")
        XCTAssertEqual(vm.destinationCaption, "Will add to Scan.pdf (1 page)")
    }

    func testRepeatedPlatenScansBuildOneDocument() async throws {
        let writer = InMemoryDestinationWriter(folders: [defaultTestFolder])
        let vm = makeAppendVM(pages: [try makeTestJPEG(width: 40, height: 30)], writer: writer)
        vm.appendToExistingPDF = true

        for expected in ["Saved Scan.pdf to Scans", "Added 1 page to Scan.pdf (2 pages)", "Added 1 page to Scan.pdf (3 pages)"] {
            XCTAssertTrue(vm.canScan)
            vm.startScan()
            try await waitForCondition(timeout: 2) { vm.saveStatus != nil }
            XCTAssertEqual(vm.statusMessage, expected)
        }

        XCTAssertEqual(Array(writer.files.keys), [scanPDF.path])
        XCTAssertEqual(writer.pdfPageCount(at: scanPDF), 3)
    }

    func testADFScanAppendsAllItsPagesInOrder() async throws {
        let pages = [try makeTestJPEG(width: 300, height: 150), try makeTestJPEG(width: 150, height: 300)]
        let writer = InMemoryDestinationWriter(files: [scanPDF: try makePDF(pageCount: 1)], folders: [defaultTestFolder])
        let vm = makeAppendVM(pages: pages, writer: writer)
        vm.platenFileType = .png
        vm.inputSource = .adf
        XCTAssertTrue(vm.canAppendToExistingPDF, "An ADF ScanJob is always PDF")
        vm.appendToExistingPDF = true

        vm.startScan()
        try await waitForCondition(timeout: 2) { vm.saveStatus != nil }

        XCTAssertEqual(writer.writes, [.init(pages: pages, dpi: 300, url: scanPDF, fileType: .pdf, append: true)])
        XCTAssertEqual(vm.statusMessage, "Added 2 pages to Scan.pdf (3 pages)")
        let document = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(writer.files[scanPDF.path])))
        let landscape = (0..<3).compactMap { document.page(at: $0)?.bounds(for: .mediaBox).size }.map { $0.width > $0.height }
        XCTAssertEqual(landscape, [false, true, false])
    }

    func testUncheckedDefersToIncrement() async throws {
        let page = try makeTestJPEG(width: 40, height: 30)
        let original = try makePDF(pageCount: 3)
        let writer = InMemoryDestinationWriter(files: [scanPDF: original], folders: [defaultTestFolder])
        let vm = makeAppendVM(pages: [page], writer: writer)
        XCTAssertFalse(vm.appendToExistingPDF, "Unticked by default")
        XCTAssertEqual(vm.destinationCaption, "Scan.pdf exists. Will save as Scan 2.pdf")

        vm.startScan()
        try await waitForCondition(timeout: 2) { vm.saveStatus != nil }

        let incremented = defaultTestFolder.appendingPathComponent("Scan 2.pdf")
        XCTAssertEqual(
            writer.writes,
            [.init(pages: [page], dpi: 300, url: incremented, fileType: .pdf, append: false)]
        )
        XCTAssertEqual(writer.files[scanPDF.path], original, "The existing PDF is untouched")
        XCTAssertEqual(vm.statusMessage, "Saved Scan 2.pdf to Scans")
    }

    func testBlockedAppendTargetMakesCanScanFalse() throws {
        let cases: [(PDFAppendTarget, DestinationPlan, String)] = [
            (.protected, .blocked(.appendTargetProtected(scanPDF)), "Scan.pdf is protected and can't be added to"),
            (.unusable, .blocked(.appendTargetUnusable(scanPDF)), "Scan.pdf can't be opened as a PDF")
        ]
        for (target, plan, caption) in cases {
            let writer = InMemoryDestinationWriter(files: [scanPDF: try makePDF(pageCount: 2)], folders: [defaultTestFolder])
            writer.forceAppendTarget(target, at: scanPDF)
            let vm = makeAppendVM(pages: [], writer: writer)
            XCTAssertTrue(vm.canScan, "Unticked, the file is only a taken name")

            vm.appendToExistingPDF = true
            XCTAssertFalse(vm.canScan)
            XCTAssertEqual(vm.destinationPlan, plan)
            XCTAssertEqual(vm.destinationCaption, caption)

            vm.appendToExistingPDF = false
            XCTAssertTrue(vm.canScan)
            XCTAssertEqual(vm.destinationCaption, "Scan.pdf exists. Will save as Scan 2.pdf")
        }
    }

    func testNonPDFBytesAtTheNameBlockScan() {
        let writer = InMemoryDestinationWriter(files: [scanPDF: Data("not a PDF".utf8)], folders: [defaultTestFolder])
        let vm = makeAppendVM(pages: [], writer: writer)
        vm.appendToExistingPDF = true

        XCTAssertFalse(vm.canScan)
        XCTAssertEqual(vm.destinationCaption, "Scan.pdf can't be opened as a PDF")
    }

    func testStartScanCreatesNoScanJobWithABlockedAppendTarget() async throws {
        let writer = InMemoryDestinationWriter(files: [scanPDF: Data("not a PDF".utf8)], folders: [defaultTestFolder])
        let vm = makeAppendVM(pages: [Fixtures.minimalJPEG], writer: writer)
        vm.appendToExistingPDF = true

        vm.startScan()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(vm.scanTask)
        XCTAssertNil(vm.jobState)
        XCTAssertTrue(writer.writes.isEmpty)
    }

    func testAppendCheckboxIsOnlyOfferedForPDFAndItsValueIsIgnoredOtherwise() async throws {
        let page = try makeTestJPEG(width: 40, height: 30)
        let writer = InMemoryDestinationWriter(folders: [defaultTestFolder])
        let vm = makeAppendVM(pages: [page], writer: writer)
        XCTAssertTrue(vm.canAppendToExistingPDF)
        vm.appendToExistingPDF = true

        for type in [FileType.png, .jpeg, .tiff] {
            vm.platenFileType = type
            XCTAssertFalse(vm.canAppendToExistingPDF, "\(type)")
            XCTAssertFalse(vm.destination.append, "\(type)")
            XCTAssertEqual(vm.destinationCaption, "Will create Scan.\(type.fileExtension)")
        }

        vm.platenFileType = .png
        vm.startScan()
        try await waitForCondition(timeout: 2) { vm.saveStatus != nil }
        XCTAssertEqual(writer.writes.map(\.append), [false])
        XCTAssertEqual(vm.destinationCaption, "Scan.png exists. Will save as Scan 2.png")

        vm.platenFileType = .pdf
        XCTAssertTrue(vm.canAppendToExistingPDF)
        XCTAssertEqual(vm.destinationCaption, "Scan.pdf doesn't exist yet. Will create it",
                       "Still ticked for this session when PDF comes back")
    }

    func testAppendStartsUntickedOnEveryLaunch() {
        let defaults = makeIsolatedDefaults()
        func launch() -> ScanViewModel {
            ScanViewModel(
                scannerFactory: { _ in MockScanner(states: [], result: .success([])) },
                discoveryFactory: { MockDiscovery() },
                destinationWriter: InMemoryDestinationWriter(folders: [defaultTestFolder]),
                defaults: defaults
            )
        }

        let first = launch()
        XCTAssertFalse(first.appendToExistingPDF)
        first.platenFileType = .pdf
        first.appendToExistingPDF = true

        let relaunched = launch()
        XCTAssertEqual(relaunched.platenFileType, .pdf, "The file type is remembered")
        XCTAssertFalse(relaunched.appendToExistingPDF, "Append is not")
    }

    func testAppendTargetThatBecameUnusableFailsTheSaveAndNeverCreatesAnotherFile() async throws {
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

        let page = try makeTestJPEG(width: 40, height: 30)
        let scanner = GatedScanner(pages: [page])
        let writer = InMemoryDestinationWriter(files: [scanPDF: try makePDF(pageCount: 2)], folders: [defaultTestFolder])
        let vm = ScanViewModel(
            scannerFactory: { _ in scanner },
            discoveryFactory: { MockDiscovery() },
            destinationWriter: writer,
            defaults: makeIsolatedDefaults()
        )
        vm.selectedTarget = nil
        vm.manualHost = "192.168.1.66"
        vm.selectedRegion = defaultTestRegion
        vm.platenFileType = .pdf
        vm.destinationFolder = defaultTestFolder
        vm.appendToExistingPDF = true
        XCTAssertEqual(vm.destinationCaption, "Will add to Scan.pdf (2 pages)")

        vm.startScan()
        while await !scanner.isWaiting { try await Task.sleep(nanoseconds: 5_000_000) }
        // Another app replaces Scan.pdf with something else while the Scanner works.
        let replacement = Data("no longer a PDF".utf8)
        writer.setFile(replacement, at: scanPDF)
        await scanner.finish()
        try await waitForCondition(timeout: 2) { vm.saveStatus != nil }

        XCTAssertEqual(vm.saveStatus, .failed("Scan.pdf can't be opened as a PDF"))
        XCTAssertEqual(vm.statusMessage, "Not saved. Scan.pdf can't be opened as a PDF")
        XCTAssertTrue(writer.writes.isEmpty)
        XCTAssertEqual(writer.files, [scanPDF.path: replacement], "Nothing was created under another name")
        XCTAssertEqual(vm.previewPages, [page], "The pages stay in memory for Retry Save")
        XCTAssertFalse(vm.canScan)

        // The file is put right; Retry Save adds the page to it.
        writer.setFile(try makePDF(pageCount: 2), at: scanPDF)
        vm.retrySave()

        XCTAssertEqual(writer.writes, [.init(pages: [page], dpi: 300, url: scanPDF, fileType: .pdf, append: true)])
        XCTAssertEqual(vm.statusMessage, "Added 1 page to Scan.pdf (3 pages)")
    }

    func testWriterRefusingAnAppendFailsTheSaveWithItsReason() async throws {
        let page = try makeTestJPEG(width: 40, height: 30)
        let writer = InMemoryDestinationWriter(files: [scanPDF: try makePDF(pageCount: 2)], folders: [defaultTestFolder])
        let vm = makeAppendVM(pages: [page], writer: writer)
        vm.appendToExistingPDF = true
        writer.failWrites(with: DestinationWriteError.appendTargetProtected(scanPDF))
        let original = writer.files

        vm.startScan()
        try await waitForCondition(timeout: 2) { vm.saveStatus != nil }

        XCTAssertEqual(vm.saveStatus, .failed("Scan.pdf is protected and can't be added to"))
        XCTAssertEqual(writer.files, original)
        XCTAssertEqual(vm.previewPages, [page])
    }

    // MARK: - selectedTarget tests

    func testActiveHostFromSelectedTarget() {
        let vm = ScanViewModel()
        let target = ScannerTarget(host: "10.0.0.5", displayName: "Samsung M2070", source: .discovered)
        vm.selectedTarget = target
        XCTAssertEqual(vm.activeHost, "10.0.0.5")
    }

    func testActiveHostFromManualHostWhenNoTargetSelected() {
        let vm = ScanViewModel()
        vm.selectedTarget = nil
        vm.manualHost = "192.168.1.99"
        XCTAssertEqual(vm.activeHost, "192.168.1.99")
    }

    func testActiveHostNilWhenNeitherSet() {
        let vm = ScanViewModel()
        vm.selectedTarget = nil
        vm.manualHost = "   "
        XCTAssertNil(vm.activeHost)
    }

    func testScanUsesSelectedTargetHost() async throws {
        let capturedHost = CapturedHost()
        let mock = MockScanner(states: [], result: .success([Fixtures.minimalJPEG]))
        let vm = ScanViewModel(
            scannerFactory: { host in Task { await capturedHost.set(host) }; return mock },
            discoveryFactory: { MockDiscovery() },
            destinationWriter: InMemoryDestinationWriter(folders: [defaultTestFolder]),
            defaults: makeIsolatedDefaults()
        )
        let target = ScannerTarget(host: "10.0.0.42", displayName: nil, source: .discovered)
        vm.selectedTarget = target
        vm.selectedRegion = defaultTestRegion
        vm.destinationFolder = defaultTestFolder

        vm.startScan()
        try await waitForCondition(timeout: 2) { vm.isScanComplete }

        let host = await capturedHost.value
        XCTAssertEqual(host, "10.0.0.42")
    }

    // MARK: - Discovery integration tests

    func testStartDiscoverySetsIsDiscovering() async throws {
        struct SlowDiscovery: ScannerDiscoveryProtocol {
            func start(onFound: @escaping @Sendable (ScannerTarget) -> Void) async {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
            func stop() async {}
        }
        let vm = ScanViewModel(
            scannerFactory: { _ in MockScanner(states: [], result: .success([])) },
            discoveryFactory: { SlowDiscovery() }
        )

        vm.startDiscovery()
        try await waitForCondition(timeout: 1) { vm.isDiscovering }
        XCTAssertTrue(vm.isDiscovering)

        vm.stopDiscovery()
        try await waitForCondition(timeout: 2) { !vm.isDiscovering }
        XCTAssertFalse(vm.isDiscovering)
    }

    func testIsDiscoveringDropsToFalseAfterProbeCompletes() async throws {
        // start() is truly async — isDiscovering must be false after each probe.
        let transport = MockDiscoveryTransport(responses: [])
        let vm = ScanViewModel(
            scannerFactory: { _ in MockScanner(states: [], result: .success([])) },
            discoveryFactory: { WSScannerDiscovery(transport: transport) }
        )

        vm.startDiscovery()
        // Wait for at least one full probe cycle to complete.
        try await waitForCondition(timeout: 5) { !vm.isDiscovering }
        XCTAssertFalse(vm.isDiscovering)
    }

    func testDiscoveredTargetsPopulateFromDiscovery() async throws {
        let targets = [
            ScannerTarget(host: "10.0.0.1", displayName: "Scanner A", source: .discovered),
            ScannerTarget(host: "10.0.0.2", displayName: "Scanner B", source: .discovered),
        ]
        let vm = ScanViewModel(
            scannerFactory: { _ in MockScanner(states: [], result: .success([])) },
            discoveryFactory: { MockDiscovery(targets: targets) }
        )

        vm.startDiscovery()
        try await waitForCondition(timeout: 2) { vm.discoveredTargets.count >= 2 }

        XCTAssertEqual(vm.discoveredTargets.count, 2)
        XCTAssertTrue(vm.discoveredTargets.contains { $0.host == "10.0.0.1" })
        XCTAssertTrue(vm.discoveredTargets.contains { $0.host == "10.0.0.2" })
    }

    func testDuplicateDiscoveredTargetsAreDeduped() async throws {
        let duplicate = ScannerTarget(host: "10.0.0.1", displayName: nil, source: .discovered)
        let vm = ScanViewModel(
            scannerFactory: { _ in MockScanner(states: [], result: .success([])) },
            discoveryFactory: { MockDiscovery(targets: [duplicate, duplicate]) }
        )

        vm.startDiscovery()
        // Wait until at least the first callback has been processed.
        try await waitForCondition(timeout: 2) { vm.discoveredTargets.count >= 1 }
        // Yield briefly so any remaining pending callbacks (the duplicate) also run.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.discoveredTargets.count, 1)
    }

    // MARK: - Persistence tests

    func testSavedTargetRoundTripsThroughPersistence() async throws {
        let testHost = "192.168.99.99"

        UserDefaults.standard.removeObject(forKey: "savedTargets")
        UserDefaults.standard.removeObject(forKey: "lastUsedHost")
        UserDefaults.standard.removeObject(forKey: "ipAddress")
        defer {
            UserDefaults.standard.removeObject(forKey: "savedTargets")
            UserDefaults.standard.removeObject(forKey: "lastUsedHost")
        }

        // Scan with a manual host — resolveHost() should save it to UserDefaults.
        let mock = MockScanner(states: [], result: .success([Fixtures.minimalJPEG]))
        let vm = makeVM(mock: mock)
        vm.manualHost = testHost
        vm.startScan()
        try await waitForCondition(timeout: 2) { vm.isScanComplete }
        XCTAssertTrue(vm.savedTargets.contains { $0.host == testHost }, "Manual host should be in savedTargets after scan")

        // A fresh VM should restore the saved target from UserDefaults.
        let vm2 = makeVM(mock: MockScanner(states: [], result: .success([])))
        XCTAssertTrue(vm2.savedTargets.contains { $0.host == testHost }, "Saved targets should persist across VM instances")
        XCTAssertEqual(vm2.selectedTarget?.host, testHost, "Last-used target should be restored as selectedTarget")
    }

    func testRemovedTargetDoesNotResurrectFromLegacyIPAddressKeyOnRelaunch() throws {
        let testHost = "192.168.99.99"

        UserDefaults.standard.removeObject(forKey: "savedTargets")
        UserDefaults.standard.removeObject(forKey: "lastUsedHost")
        UserDefaults.standard.set(testHost, forKey: "ipAddress")
        defer {
            UserDefaults.standard.removeObject(forKey: "savedTargets")
            UserDefaults.standard.removeObject(forKey: "lastUsedHost")
            UserDefaults.standard.removeObject(forKey: "ipAddress")
        }

        // First launch migrates the legacy ipAddress key into savedTargets.
        let vm = makeVM(mock: MockScanner(states: [], result: .success([])))
        XCTAssertTrue(vm.savedTargets.contains { $0.host == testHost })

        vm.removeSavedTarget(ScannerTarget(host: testHost, displayName: nil, source: .manual))
        XCTAssertFalse(vm.savedTargets.contains { $0.host == testHost })

        // A relaunch must not re-migrate the now-deleted host back in.
        let vm2 = makeVM(mock: MockScanner(states: [], result: .success([])))
        XCTAssertFalse(vm2.savedTargets.contains { $0.host == testHost }, "Deleted target should not reappear via legacy ipAddress migration")
    }

    // MARK: - Manage Devices (removeSavedTarget) tests

    private func makeVMWithSavedTargets(_ targets: [ScannerTarget]) -> ScanViewModel {
        UserDefaults.standard.removeObject(forKey: "savedTargets")
        UserDefaults.standard.removeObject(forKey: "lastUsedHost")
        UserDefaults.standard.removeObject(forKey: "ipAddress")
        let data = try! JSONEncoder().encode(targets)
        UserDefaults.standard.set(data, forKey: "savedTargets")
        return ScanViewModel(
            scannerFactory: { _ in MockScanner(states: [], result: .success([])) },
            discoveryFactory: { MockDiscovery() }
        )
    }

    private func clearSavedTargetsDefaults() {
        UserDefaults.standard.removeObject(forKey: "savedTargets")
        UserDefaults.standard.removeObject(forKey: "lastUsedHost")
    }

    // MARK: - Saved-target displayName backfill

    func testResolvedNameBackfillsSavedTargetAndPersists() async throws {
        let host = "192.168.1.66"
        _ = makeVMWithSavedTargets([ScannerTarget(host: host, displayName: nil, source: .manual)])
        defer { clearSavedTargetsDefaults() }

        // Discovery delivers the ScannerTarget first without a name, then again
        // once the name has resolved.
        let deliveries = [
            ScannerTarget(host: host, displayName: nil, source: .discovered),
            ScannerTarget(host: host, displayName: "Fullyautomatix", source: .discovered),
        ]
        let discovering = ScanViewModel(
            scannerFactory: { _ in MockScanner(states: [], result: .success([])) },
            discoveryFactory: { MockDiscovery(targets: deliveries) }
        )
        XCTAssertNil(discovering.savedTargets.first?.displayName)
        discovering.selectTarget(byHost: host)

        discovering.startDiscovery()
        try await waitForCondition(timeout: 2) {
            discovering.savedTargets.first?.displayName == "Fullyautomatix"
        }
        discovering.stopDiscovery()

        XCTAssertEqual(discovering.savedTargets.map(\.host), [host], "host stays the IP")
        XCTAssertEqual(discovering.selectedTarget?.displayName, "Fullyautomatix")

        // The name survives relaunch.
        let relaunched = ScanViewModel(
            scannerFactory: { _ in MockScanner(states: [], result: .success([])) },
            discoveryFactory: { MockDiscovery() }
        )
        XCTAssertEqual(relaunched.savedTargets.first?.host, host)
        XCTAssertEqual(relaunched.savedTargets.first?.displayName, "Fullyautomatix")
    }

    func testResolvedNameDoesNotOverwriteExistingSavedDisplayName() async throws {
        let host = "192.168.1.66"
        _ = makeVMWithSavedTargets([ScannerTarget(host: host, displayName: "Office", source: .manual)])
        defer { clearSavedTargetsDefaults() }

        let vm = ScanViewModel(
            scannerFactory: { _ in MockScanner(states: [], result: .success([])) },
            discoveryFactory: {
                MockDiscovery(targets: [ScannerTarget(host: host, displayName: "Fullyautomatix", source: .discovered)])
            }
        )
        vm.startDiscovery()
        try await waitForCondition(timeout: 2) { vm.discoveredTargets.count >= 1 }
        vm.stopDiscovery()

        XCTAssertEqual(vm.savedTargets.first?.displayName, "Office")
    }

    func testHostInBothDiscoveredAndSavedIsListedOnceInPicker() async throws {
        let saved = ScannerTarget(host: "192.168.1.66", displayName: nil, source: .manual)
        _ = makeVMWithSavedTargets([saved])
        defer { clearSavedTargetsDefaults() }

        let vm = ScanViewModel(
            scannerFactory: { _ in MockScanner(states: [], result: .success([])) },
            discoveryFactory: {
                MockDiscovery(targets: [
                    ScannerTarget(host: "192.168.1.66", displayName: nil, source: .discovered),
                    ScannerTarget(host: "192.168.1.77", displayName: nil, source: .discovered),
                ])
            }
        )
        vm.startDiscovery()
        try await waitForCondition(timeout: 2) { vm.discoveredTargets.count >= 2 }
        vm.stopDiscovery()

        // The picker lists unsavedDiscoveredTargets under Discovered and savedTargets under Saved.
        XCTAssertEqual(vm.unsavedDiscoveredTargets.map(\.host), ["192.168.1.77"])
        XCTAssertEqual(vm.savedTargets.map(\.host), ["192.168.1.66"])
    }

    func testRemoveSavedTargetRemovesFromListAndPersists() throws {
        let a = ScannerTarget(host: "10.0.0.1", displayName: "A", source: .manual)
        let b = ScannerTarget(host: "10.0.0.2", displayName: "B", source: .manual)
        let vm = makeVMWithSavedTargets([a, b])
        defer { clearSavedTargetsDefaults() }

        vm.removeSavedTarget(a)

        XCTAssertEqual(vm.savedTargets.map(\.host), ["10.0.0.2"])

        // Persistence: a freshly loaded VM should not see the removed target.
        let vm2 = ScanViewModel(
            scannerFactory: { _ in MockScanner(states: [], result: .success([])) },
            discoveryFactory: { MockDiscovery() }
        )
        XCTAssertEqual(vm2.savedTargets.map(\.host), ["10.0.0.2"])
    }

    func testRemoveSavedTargetFallsBackToFirstRemainingWhenSelectedTargetRemoved() throws {
        let a = ScannerTarget(host: "10.0.0.1", displayName: "A", source: .manual)
        let b = ScannerTarget(host: "10.0.0.2", displayName: "B", source: .manual)
        let vm = makeVMWithSavedTargets([a, b])
        defer { clearSavedTargetsDefaults() }
        vm.selectedTarget = a

        vm.removeSavedTarget(a)

        XCTAssertEqual(vm.selectedTarget?.host, "10.0.0.2")
    }

    func testRemoveSavedTargetClearsSelectionWhenNoneRemain() throws {
        let a = ScannerTarget(host: "10.0.0.1", displayName: "A", source: .manual)
        let vm = makeVMWithSavedTargets([a])
        defer { clearSavedTargetsDefaults() }
        vm.selectedTarget = a

        vm.removeSavedTarget(a)

        XCTAssertTrue(vm.savedTargets.isEmpty)
        XCTAssertNil(vm.selectedTarget)
    }

    func testRemoveSavedTargetLeavesSelectionUnchangedWhenRemovingAnotherTarget() throws {
        let a = ScannerTarget(host: "10.0.0.1", displayName: "A", source: .manual)
        let b = ScannerTarget(host: "10.0.0.2", displayName: "B", source: .manual)
        let vm = makeVMWithSavedTargets([a, b])
        defer { clearSavedTargetsDefaults() }
        vm.selectedTarget = a

        vm.removeSavedTarget(b)

        XCTAssertEqual(vm.selectedTarget?.host, "10.0.0.1")
        XCTAssertEqual(vm.savedTargets.map(\.host), ["10.0.0.1"])
    }

    // MARK: - Helpers

    private func waitForCondition(timeout: TimeInterval, condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
    }
}

// MARK: - Thread-safe host capture

actor CapturedHost {
    private(set) var value: String?
    func set(_ host: String) { value = host }
}
