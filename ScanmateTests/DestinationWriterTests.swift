import ImageIO
import PDFKit
import XCTest
@testable import Scanimate

// MARK: - In-memory fake

/// A `DestinationWriter` that keeps everything in memory. It encodes with the
/// production encoder, so `files` holds the exact bytes the real writer would
/// put on disk, but nothing touches the filesystem.
final class InMemoryDestinationWriter: DestinationWriter, @unchecked Sendable {
    struct Write: Equatable {
        let pages: [Data]
        let dpi: Int
        let url: URL
        let fileType: FileType
        let append: Bool
    }

    private let lock = NSLock()
    private var storedFiles: [URL: Data]
    private var recordedWrites: [Write] = []
    private let writeError: Error?

    init(files: [URL: Data] = [:], writeError: Error? = nil) {
        self.storedFiles = files
        self.writeError = writeError
    }

    /// Every file "on disk", by URL.
    var files: [URL: Data] { lock.withLock { storedFiles } }
    /// Every `write` call, in order.
    var writes: [Write] { lock.withLock { recordedWrites } }

    func fileExists(at url: URL) -> Bool {
        files[url] != nil
    }

    func pdfPageCount(at url: URL) -> Int? {
        guard let data = files[url] else { return nil }
        return PDFDocument(data: data)?.pageCount
    }

    func write(pages: [Data], dpi: Int, to url: URL, as fileType: FileType, append: Bool) throws {
        if let writeError { throw writeError }
        let data = try FileDestinationWriter.encode(pages: pages, dpi: dpi, as: fileType)
        lock.withLock {
            recordedWrites.append(Write(pages: pages, dpi: dpi, url: url, fileType: fileType, append: append))
            storedFiles[url] = data
        }
    }
}

// MARK: - Tests

@MainActor
final class DestinationWriterTests: XCTestCase {

    private let host = "192.168.1.66"
    private let folder = URL(fileURLWithPath: "/nonexistent-scanimate-tests/Scans", isDirectory: true)

    // MARK: Platen

    func testPlatenScanSavedWithDefaultsWritesOnePNG() async throws {
        let page = try makeJPEG(width: 40, height: 30)
        let writer = InMemoryDestinationWriter()
        let vm = try await completedScan(pages: [page], source: .flatbed, writer: writer)
        vm.resolution = .dpi300

        XCTAssertEqual(vm.defaultFileType, .png)
        XCTAssertEqual(vm.allowedFileTypes, [.png, .tiff])
        XCTAssertEqual(vm.suggestedFilename, "Scan.png")

        let url = folder.appendingPathComponent(vm.suggestedFilename)
        vm.writeScanResult(to: url)

        XCTAssertEqual(
            writer.writes,
            [.init(pages: [page], dpi: 300, url: url, fileType: .png, append: false)]
        )
        XCTAssertEqual(Array(writer.files.keys), [url])
        XCTAssertEqual(url.lastPathComponent, "Scan.png")

        let bytes = try XCTUnwrap(writer.files[url])
        XCTAssertEqual(bytes, try FileDestinationWriter.encode(pages: [page], dpi: 300, as: .png))
        let image = try describeImage(bytes)
        XCTAssertEqual(image.type, "public.png")
        XCTAssertEqual(image.width, 40)
        XCTAssertEqual(image.height, 30)
        XCTAssertEqual(image.dpi, 300, accuracy: 0.5)
        XCTAssertEqual(image.frameCount, 1)

        XCTAssertNil(vm.alertError)
        XCTAssertNil(vm.jobState, "A successful save resets for the next ScanJob")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "The fake must not touch the filesystem")
    }

    func testPlatenScanSavedAsTIFFWritesTIFFAtTheTicketResolution() async throws {
        let page = try makeJPEG(width: 20, height: 10)
        let writer = InMemoryDestinationWriter()
        let vm = try await completedScan(pages: [page], source: .flatbed, writer: writer)
        vm.resolution = .dpi600

        for name in ["Photo.tiff", "Photo.TIF"] {
            let url = folder.appendingPathComponent(name)
            vm.writeScanResult(to: url)
            XCTAssertEqual(writer.writes.last?.url, url)
            XCTAssertEqual(writer.writes.last?.fileType, .tiff)
            XCTAssertEqual(writer.writes.last?.dpi, 600)

            let image = try describeImage(try XCTUnwrap(writer.files[url]))
            XCTAssertEqual(image.type, "public.tiff")
            XCTAssertEqual(image.width, 20)
            XCTAssertEqual(image.height, 10)
            XCTAssertEqual(image.dpi, 600, accuracy: 0.5)

            // A successful save resets the view model, so scan again for the next name.
            vm.startScan()
            try await waitForCondition { vm.isScanComplete }
        }
        XCTAssertEqual(writer.writes.count, 2)
    }

    func testPlatenScanNeverWritesPDFEvenWithPDFExtension() async throws {
        let page = try makeJPEG(width: 8, height: 8)
        let writer = InMemoryDestinationWriter()
        let vm = try await completedScan(pages: [page], source: .flatbed, writer: writer)

        let url = folder.appendingPathComponent("Scan.pdf")
        vm.writeScanResult(to: url)

        XCTAssertEqual(writer.writes.map(\.fileType), [.png])
        XCTAssertEqual(try describeImage(try XCTUnwrap(writer.files[url])).type, "public.png")
    }

    // MARK: ADF

    func testADFScanSavedWithDefaultsWritesOneMultiPagePDF() async throws {
        let pages = [
            try makeJPEG(width: 40, height: 30),
            try makeJPEG(width: 30, height: 40),
            try makeJPEG(width: 50, height: 50)
        ]
        let writer = InMemoryDestinationWriter()
        let vm = try await completedScan(pages: pages, source: .adf, writer: writer)

        XCTAssertEqual(vm.defaultFileType, .pdf)
        XCTAssertEqual(vm.allowedFileTypes, [.pdf, .png, .tiff])
        XCTAssertEqual(vm.suggestedFilename, "Scan.pdf")

        let url = folder.appendingPathComponent(vm.suggestedFilename)
        XCTAssertFalse(writer.fileExists(at: url))
        XCTAssertNil(writer.pdfPageCount(at: url))

        vm.writeScanResult(to: url)

        XCTAssertEqual(
            writer.writes,
            [.init(pages: pages, dpi: 300, url: url, fileType: .pdf, append: false)]
        )
        XCTAssertEqual(Array(writer.files.keys), [url])

        let bytes = try XCTUnwrap(writer.files[url])
        XCTAssertEqual(String(decoding: bytes.prefix(5), as: UTF8.self), "%PDF-")
        let document = try XCTUnwrap(PDFDocument(data: bytes))
        XCTAssertEqual(document.pageCount, 3)
        // Page order follows the order the sheets were fed.
        let sizes = (0..<3).compactMap { document.page(at: $0)?.bounds(for: .mediaBox).size }
        XCTAssertEqual(sizes.map { $0.width > $0.height }, [true, false, false])
        XCTAssertEqual(sizes.map { $0.width == $0.height }, [false, false, true])

        XCTAssertTrue(writer.fileExists(at: url))
        XCTAssertEqual(writer.pdfPageCount(at: url), 3)
        XCTAssertNil(vm.jobState)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "The fake must not touch the filesystem")
    }

    func testADFScanSavedAsPNGWritesOnlyTheFirstPage() async throws {
        let pages = [try makeJPEG(width: 40, height: 30), try makeJPEG(width: 30, height: 40)]
        let writer = InMemoryDestinationWriter()
        let vm = try await completedScan(pages: pages, source: .adf, writer: writer)

        let url = folder.appendingPathComponent("Scan.png")
        vm.writeScanResult(to: url)

        XCTAssertEqual(writer.writes.map(\.fileType), [.png])
        let image = try describeImage(try XCTUnwrap(writer.files[url]))
        XCTAssertEqual(image.type, "public.png")
        XCTAssertEqual(image.width, 40)
        XCTAssertEqual(image.height, 30)
        XCTAssertNil(writer.pdfPageCount(at: url), "A PNG is not a PDF that can be added to")
    }

    // MARK: Failure and gating

    func testFailedWriteKeepsTheScanResultAndRaisesAnAlert() async throws {
        let page = try makeJPEG(width: 8, height: 8)
        let writer = InMemoryDestinationWriter(writeError: ScanError.protocolError("disk full"))
        let vm = try await completedScan(pages: [page], source: .flatbed, writer: writer)

        vm.writeScanResult(to: folder.appendingPathComponent("Scan.png"))

        XCTAssertTrue(vm.isScanComplete, "The ScanResult stays so the user can save again")
        XCTAssertTrue(writer.files.isEmpty)
        guard case .protocolError(let message)? = vm.alertError else {
            return XCTFail("Expected a save-failed alert, got \(String(describing: vm.alertError))")
        }
        XCTAssertTrue(message.hasPrefix("Save failed:"), message)
    }

    func testNothingIsWrittenWithoutACompletedScanJob() {
        let writer = InMemoryDestinationWriter()
        let vm = ScanViewModel(
            scannerFactory: { _ in MockScanner(states: [], result: .success([])) },
            discoveryFactory: { MockDiscovery() },
            destinationWriter: writer
        )

        vm.writeScanResult(to: folder.appendingPathComponent("Scan.png"))

        XCTAssertTrue(writer.writes.isEmpty)
        XCTAssertTrue(writer.files.isEmpty)
    }

    // MARK: Encoder and FileType

    func testJPEGOutputIsNotAvailableYet() throws {
        let page = try makeJPEG(width: 8, height: 8)
        XCTAssertThrowsError(try FileDestinationWriter.encode(pages: [page], dpi: 300, as: .jpeg))
    }

    func testUndecodablePageFailsInsteadOfWritingGarbage() {
        let garbage = Data("not a jpeg".utf8)
        XCTAssertThrowsError(try FileDestinationWriter.encode(pages: [garbage], dpi: 300, as: .png))
        XCTAssertThrowsError(try FileDestinationWriter.encode(pages: [garbage], dpi: 300, as: .pdf))
    }

    func testFileTypeExtensionsAndDisplayNames() {
        XCTAssertEqual(FileType.allCases, [.pdf, .png, .jpeg, .tiff])
        XCTAssertEqual(FileType.allCases.map(\.fileExtension), ["pdf", "png", "jpg", "tiff"])
        XCTAssertEqual(FileType.allCases.map(\.displayName), ["PDF", "PNG", "JPEG", "TIFF"])
    }

    // MARK: - Helpers

    /// Runs a ScanJob to completion against a mock Scanner returning `pages`.
    private func completedScan(
        pages: [Data],
        source: InputSource,
        writer: InMemoryDestinationWriter
    ) async throws -> ScanViewModel {
        let mock = MockScanner(states: [.checkingScanner], result: .success(pages))
        let vm = ScanViewModel(
            scannerFactory: { _ in mock },
            discoveryFactory: { MockDiscovery() },
            destinationWriter: writer
        )
        vm.selectedRegion = ScanRegion(xOffset: 0, yOffset: 0, width: 8500, height: 11000)
        vm.selectedTarget = nil
        vm.manualHost = host
        vm.inputSource = source
        vm.startScan()
        try await waitForCondition { vm.isScanComplete }
        XCTAssertTrue(writer.writes.isEmpty, "Completing a ScanJob does not save by itself")
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

    /// A real, decodable JPEG built in memory, standing in for a page from the Scanner.
    private func makeJPEG(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())

        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private struct ImageDescription {
        let type: String
        let width: Int
        let height: Int
        let dpi: Double
        let frameCount: Int
    }

    private func describeImage(_ data: Data) throws -> ImageDescription {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let type = try XCTUnwrap(CGImageSourceGetType(source)) as String
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return ImageDescription(
            type: type,
            width: try XCTUnwrap(props[kCGImagePropertyPixelWidth] as? Int),
            height: try XCTUnwrap(props[kCGImagePropertyPixelHeight] as? Int),
            dpi: try XCTUnwrap(props[kCGImagePropertyDPIWidth] as? Double),
            frameCount: CGImageSourceGetCount(source)
        )
    }
}
