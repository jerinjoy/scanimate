import ImageIO
import PDFKit
import XCTest
@testable import Scanimate

// MARK: - In-memory fake

/// A `DestinationWriter` that keeps everything in memory. It encodes with the
/// production encoder, so `files` holds the exact bytes the real writer would
/// put on disk, but nothing touches the filesystem. Like the real writer it
/// needs the folder to exist and never replaces an existing file.
final class InMemoryDestinationWriter: DestinationWriter, @unchecked Sendable {
    struct Write: Equatable {
        let pages: [Data]
        let dpi: Int
        let url: URL
        let fileType: FileType
        let append: Bool
    }

    private let lock = NSLock()
    private var storedFiles: [String: Data]
    private var storedFolders: Set<String>
    private var recordedWrites: [Write] = []
    private var writeError: Error?
    private var forcedAppendTargets: [String: PDFAppendTarget] = [:]

    init(files: [URL: Data] = [:], folders: [URL] = [], writeError: Error? = nil) {
        self.storedFiles = Dictionary(uniqueKeysWithValues: files.map { ($0.key.path, $0.value) })
        self.storedFolders = Set(folders.map(\.path))
        self.writeError = writeError
    }

    /// Every file "on disk", by path.
    var files: [String: Data] { lock.withLock { storedFiles } }
    /// Every successful `write` call, in order.
    var writes: [Write] { lock.withLock { recordedWrites } }

    /// Makes every later `write` throw `error`, or succeed again when nil.
    func failWrites(with error: Error?) {
        lock.withLock { writeError = error }
    }

    func addFolder(_ url: URL) {
        lock.withLock { _ = storedFolders.insert(url.path) }
    }

    /// Simulates the folder being deleted or its volume unmounted.
    func removeFolder(_ url: URL) {
        lock.withLock { _ = storedFolders.remove(url.path) }
    }

    /// Simulates another app creating, replacing or (with nil) deleting a file.
    func setFile(_ data: Data?, at url: URL) {
        lock.withLock { storedFiles[url.path] = data }
    }

    /// Makes `appendTarget(at:)` answer `target` for the file at `url` whatever
    /// its bytes — a read-only or protected file — or go by the bytes again when nil.
    func forceAppendTarget(_ target: PDFAppendTarget?, at url: URL) {
        lock.withLock { forcedAppendTargets[url.path] = target }
    }

    func fileExists(at url: URL) -> Bool {
        lock.withLock { storedFiles[url.path] != nil || storedFolders.contains(url.path) }
    }

    func appendTarget(at url: URL) -> PDFAppendTarget {
        lock.withLock { lockedAppendTarget(atPath: url.path) }
    }

    private func lockedAppendTarget(atPath path: String) -> PDFAppendTarget {
        guard let data = storedFiles[path] else { return .unusable }
        if let forced = forcedAppendTargets[path] { return forced }
        return FileDestinationWriter.appendTarget(for: PDFDocument(data: data))
    }

    @discardableResult
    func write(pages: [Data], dpi: Int, to url: URL, as fileType: FileType, append: Bool) throws
        -> DestinationWriteOutcome {
        let write = Write(pages: pages, dpi: dpi, url: url, fileType: fileType, append: append)
        return try lock.withLock {
            if let writeError { throw writeError }
            guard storedFolders.contains(url.deletingLastPathComponent().path) else {
                throw CocoaError(.fileNoSuchFile)
            }

            if append, fileType == .pdf, let existing = storedFiles[url.path] {
                switch lockedAppendTarget(atPath: url.path) {
                case .appendable: break
                case .protected: throw DestinationWriteError.appendTargetProtected(url)
                case .unusable: throw DestinationWriteError.appendTargetUnusable(url)
                }
                guard let document = PDFDocument(data: existing) else {
                    throw DestinationWriteError.appendTargetUnusable(url)
                }
                try FileDestinationWriter.append(pages: pages, dpi: dpi, to: document)
                guard let data = document.dataRepresentation() else {
                    throw ScanError.protocolError("Could not write PDF")
                }
                recordedWrites.append(write)
                storedFiles[url.path] = data
                return .appended(addedPageCount: pages.count, totalPageCount: document.pageCount)
            }

            let data = try FileDestinationWriter.encode(pages: pages, dpi: dpi, as: fileType)
            guard storedFiles[url.path] == nil else {
                throw CocoaError(.fileWriteFileExists)
            }
            recordedWrites.append(write)
            storedFiles[url.path] = data
            return .created
        }
    }
}

// MARK: - Shared test helpers

/// A `UserDefaults` that starts empty and is not the app's own, so tests
/// neither read nor disturb a real persisted Destination.
func makeIsolatedDefaults() -> UserDefaults {
    let suite = "com.jerinjoy.scanimate.tests.destination"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

/// A real, decodable JPEG built in memory, standing in for a page from the Scanner.
func makeTestJPEG(width: Int, height: Int) throws -> Data {
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

struct TestImageDescription {
    let type: String
    let width: Int
    let height: Int
    let dpi: Double
    let frameCount: Int
}

func describeTestImage(_ data: Data) throws -> TestImageDescription {
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    let type = try XCTUnwrap(CGImageSourceGetType(source)) as String
    let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    return TestImageDescription(
        type: type,
        width: try XCTUnwrap(props[kCGImagePropertyPixelWidth] as? Int),
        height: try XCTUnwrap(props[kCGImagePropertyPixelHeight] as? Int),
        dpi: try XCTUnwrap(props[kCGImagePropertyDPIWidth] as? Double),
        frameCount: CGImageSourceGetCount(source)
    )
}

// MARK: - Production writer, in a temporary directory

final class FileDestinationWriterTests: XCTestCase {

    private var folder: URL!
    private let writer = FileDestinationWriter()

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanimateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testPDFRoundTripsEveryPageInOrder() throws {
        let pages = [
            try makeTestJPEG(width: 40, height: 30),
            try makeTestJPEG(width: 30, height: 40),
            try makeTestJPEG(width: 50, height: 50)
        ]
        let url = folder.appendingPathComponent("Scan.pdf")
        XCTAssertFalse(writer.fileExists(at: url))
        XCTAssertNil(writer.pdfPageCount(at: url))

        try writer.write(pages: pages, dpi: 300, to: url, as: .pdf, append: false)

        XCTAssertTrue(writer.fileExists(at: url))
        XCTAssertEqual(writer.pdfPageCount(at: url), 3)
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(String(decoding: bytes.prefix(5), as: UTF8.self), "%PDF-")
        let document = try XCTUnwrap(PDFDocument(url: url))
        let sizes = (0..<3).compactMap { document.page(at: $0)?.bounds(for: .mediaBox).size }
        XCTAssertEqual(sizes.map { $0.width > $0.height }, [true, false, false])
        XCTAssertEqual(sizes.map { $0.width == $0.height }, [false, false, true])
    }

    func testPNGRoundTripsAtTheTicketResolution() throws {
        let page = try makeTestJPEG(width: 40, height: 30)
        let url = folder.appendingPathComponent("Scan.png")

        try writer.write(pages: [page], dpi: 300, to: url, as: .png, append: false)

        let image = try describeTestImage(try Data(contentsOf: url))
        XCTAssertEqual(image.type, "public.png")
        XCTAssertEqual(image.width, 40)
        XCTAssertEqual(image.height, 30)
        XCTAssertEqual(image.dpi, 300, accuracy: 0.5)
        XCTAssertEqual(image.frameCount, 1)
        XCTAssertNil(writer.pdfPageCount(at: url), "A PNG is not a PDF that can be added to")
    }

    func testTIFFRoundTripsAtTheTicketResolution() throws {
        let page = try makeTestJPEG(width: 20, height: 10)
        let url = folder.appendingPathComponent("Scan.tiff")

        try writer.write(pages: [page], dpi: 600, to: url, as: .tiff, append: false)

        let image = try describeTestImage(try Data(contentsOf: url))
        XCTAssertEqual(image.type, "public.tiff")
        XCTAssertEqual(image.width, 20)
        XCTAssertEqual(image.height, 10)
        XCTAssertEqual(image.dpi, 600, accuracy: 0.5)
    }

    func testJPEGIsTheScannersRawPageDataByteForByte() throws {
        let page = try makeTestJPEG(width: 40, height: 30)
        let url = folder.appendingPathComponent("Scan.jpg")

        try writer.write(pages: [page], dpi: 300, to: url, as: .jpeg, append: false)

        XCTAssertEqual(try Data(contentsOf: url), page)
    }

    func testJPEGIsNotDecodedSoEvenOpaqueBytesPassThrough() throws {
        // Proof there is no re-encode: bytes no decoder would accept come out unchanged.
        let raw = Data("raw page data from the Scanner".utf8)
        XCTAssertEqual(try FileDestinationWriter.encode(pages: [raw], dpi: 300, as: .jpeg), raw)
    }

    func testAnExistingFileIsNeverOverwritten() throws {
        let page = try makeTestJPEG(width: 8, height: 8)
        let original = Data("an earlier scan".utf8)

        for type in FileType.allCases {
            let url = folder.appendingPathComponent("Taken.\(type.fileExtension)")
            try original.write(to: url)

            XCTAssertThrowsError(try writer.write(pages: [page], dpi: 300, to: url, as: type, append: false))
            XCTAssertEqual(try Data(contentsOf: url), original, "\(type) replaced an existing file")
        }
    }

    func testWritingIntoAMissingFolderFailsAndLeavesNothingBehind() throws {
        let page = try makeTestJPEG(width: 8, height: 8)
        let gone = folder.appendingPathComponent("Gone", isDirectory: true)
        let url = gone.appendingPathComponent("Scan.png")

        XCTAssertThrowsError(try writer.write(pages: [page], dpi: 300, to: url, as: .png, append: false))
        XCTAssertFalse(writer.fileExists(at: gone))
    }

    // MARK: Append to an existing PDF

    func testAppendAddsThePageAfterTheOriginalPagesInOrder() throws {
        let url = folder.appendingPathComponent("Scan.pdf")
        // Two originals with different shapes, so their order can be told apart.
        try writer.write(
            pages: [try makeTestJPEG(width: 300, height: 150), try makeTestJPEG(width: 150, height: 300)],
            dpi: 300, to: url, as: .pdf, append: false
        )
        XCTAssertEqual(writer.appendTarget(at: url), .appendable(pageCount: 2))
        let originalSizes = try pageSizes(at: url)

        let outcome = try writer.write(
            pages: [try makeTestJPEG(width: 600, height: 600)], dpi: 300, to: url, as: .pdf, append: true
        )

        XCTAssertEqual(outcome, .appended(addedPageCount: 1, totalPageCount: 3))
        XCTAssertEqual(writer.pdfPageCount(at: url), 3)
        let sizes = try pageSizes(at: url)
        XCTAssertEqual(Array(sizes.prefix(2)), originalSizes, "The original two pages are unchanged, in order")
        XCTAssertEqual(sizes[0], CGSize(width: 72, height: 36))
        XCTAssertEqual(sizes[1], CGSize(width: 36, height: 72))
        XCTAssertEqual(sizes[2], CGSize(width: 144, height: 144), "The scanned page is last")
        XCTAssertEqual(try folderContents(), ["Scan.pdf"], "No new file, no incremented name, no temporary file")
    }

    func testAppendAddsEveryPageOfAMultiPageScanResultInOrder() throws {
        let url = folder.appendingPathComponent("Scan.pdf")
        try writer.write(pages: [try makeTestJPEG(width: 300, height: 300)], dpi: 300, to: url, as: .pdf, append: false)

        let outcome = try writer.write(
            pages: [try makeTestJPEG(width: 300, height: 150), try makeTestJPEG(width: 150, height: 300)],
            dpi: 300, to: url, as: .pdf, append: true
        )

        XCTAssertEqual(outcome, .appended(addedPageCount: 2, totalPageCount: 3))
        XCTAssertEqual(try pageSizes(at: url), [
            CGSize(width: 72, height: 72), CGSize(width: 72, height: 36), CGSize(width: 36, height: 72)
        ])
    }

    func testRepeatedAppendsBuildADocumentOnePageAtATime() throws {
        let url = folder.appendingPathComponent("Scan.pdf")
        let page = try makeTestJPEG(width: 30, height: 40)

        for expected in 1...4 {
            try writer.write(pages: [page], dpi: 300, to: url, as: .pdf, append: true)
            XCTAssertEqual(writer.pdfPageCount(at: url), expected)
        }
        XCTAssertEqual(try folderContents(), ["Scan.pdf"])
    }

    func testAppendToAMissingFileCreatesIt() throws {
        let url = folder.appendingPathComponent("Scan.pdf")

        let outcome = try writer.write(
            pages: [try makeTestJPEG(width: 40, height: 30)], dpi: 300, to: url, as: .pdf, append: true
        )

        XCTAssertEqual(outcome, .created)
        XCTAssertEqual(writer.pdfPageCount(at: url), 1)
        XCTAssertEqual(try folderContents(), ["Scan.pdf"])
    }

    func testAppendToNonPDFBytesThrowsAndLeavesTheFileByteIdentical() throws {
        let url = folder.appendingPathComponent("Scan.pdf")
        let original = Data("these bytes are not a PDF".utf8)
        try original.write(to: url)
        XCTAssertEqual(writer.appendTarget(at: url), .unusable)
        XCTAssertNil(writer.pdfPageCount(at: url))

        XCTAssertThrowsError(
            try writer.write(pages: [try makeTestJPEG(width: 8, height: 8)], dpi: 300, to: url, as: .pdf, append: true)
        ) { error in
            XCTAssertEqual(error as? DestinationWriteError, .appendTargetUnusable(url))
            XCTAssertEqual(error.localizedDescription, "Scan.pdf can't be opened as a PDF")
        }

        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try folderContents(), ["Scan.pdf"], "Nothing else was created instead")
    }

    func testAPasswordProtectedPDFIsRefusedAndLeftByteIdentical() throws {
        let url = folder.appendingPathComponent("Scan.pdf")
        try writeProtectedPDF(to: url, options: [
            .userPasswordOption: "open-sesame", .ownerPasswordOption: "owner"
        ])
        let original = try Data(contentsOf: url)
        XCTAssertEqual(writer.appendTarget(at: url), .protected)
        XCTAssertNil(writer.pdfPageCount(at: url))

        XCTAssertThrowsError(
            try writer.write(pages: [try makeTestJPEG(width: 8, height: 8)], dpi: 300, to: url, as: .pdf, append: true)
        ) { error in
            XCTAssertEqual(error as? DestinationWriteError, .appendTargetProtected(url))
            XCTAssertEqual(error.localizedDescription, "Scan.pdf is protected and can't be added to")
        }

        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try folderContents(), ["Scan.pdf"])
    }

    func testAnEncryptedPDFThatOpensWithoutAPasswordIsStillRefused() throws {
        let url = folder.appendingPathComponent("Scan.pdf")
        // Owner password only: anyone can read it, but it is encrypted.
        try writeProtectedPDF(to: url, options: [.ownerPasswordOption: "owner"])
        let original = try Data(contentsOf: url)

        XCTAssertEqual(writer.appendTarget(at: url), .protected)
        XCTAssertThrowsError(
            try writer.write(pages: [try makeTestJPEG(width: 8, height: 8)], dpi: 300, to: url, as: .pdf, append: true)
        )
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testAReadOnlyPDFIsRefusedAndLeftByteIdentical() throws {
        let url = folder.appendingPathComponent("Scan.pdf")
        try writer.write(pages: [try makeTestJPEG(width: 8, height: 8)], dpi: 300, to: url, as: .pdf, append: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        let original = try Data(contentsOf: url)
        XCTAssertEqual(writer.appendTarget(at: url), .unusable)

        XCTAssertThrowsError(
            try writer.write(pages: [try makeTestJPEG(width: 8, height: 8)], dpi: 300, to: url, as: .pdf, append: true)
        ) { error in
            XCTAssertEqual(error as? DestinationWriteError, .appendTargetUnusable(url))
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testAFolderAtTheNameIsNotAnAppendTarget() throws {
        let url = folder.appendingPathComponent("Scan.pdf")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)

        XCTAssertEqual(writer.appendTarget(at: url), .unusable)
        XCTAssertThrowsError(
            try writer.write(pages: [try makeTestJPEG(width: 8, height: 8)], dpi: 300, to: url, as: .pdf, append: true)
        )
        XCTAssertEqual(try folderContents(), ["Scan.pdf"])
    }

    func testAnAppendThatFailsPartWayLeavesTheOriginalByteIdentical() throws {
        let url = folder.appendingPathComponent("Scan.pdf")
        try writer.write(
            pages: [try makeTestJPEG(width: 40, height: 30), try makeTestJPEG(width: 30, height: 40)],
            dpi: 300, to: url, as: .pdf, append: false
        )
        let original = try Data(contentsOf: url)

        // The second scanned page cannot be decoded, so the append fails after
        // the target was opened and the first page was built.
        XCTAssertThrowsError(
            try writer.write(
                pages: [try makeTestJPEG(width: 8, height: 8), Fixtures.minimalJPEG],
                dpi: 300, to: url, as: .pdf, append: true
            )
        )

        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try folderContents(), ["Scan.pdf"], "No temporary file is left behind")
    }

    func testAppendIsIgnoredForFileTypesThatAreNotPDF() throws {
        let page = try makeTestJPEG(width: 8, height: 8)
        let original = Data("an earlier scan".utf8)

        for type in [FileType.png, .jpeg, .tiff] {
            let url = folder.appendingPathComponent("Taken.\(type.fileExtension)")
            try original.write(to: url)

            XCTAssertThrowsError(try writer.write(pages: [page], dpi: 300, to: url, as: type, append: true))
            XCTAssertEqual(try Data(contentsOf: url), original, "\(type) replaced an existing file")
        }
    }

    func testPDFPagesAreSizedFromTheTicketResolution() throws {
        // 2550 × 3300 pixels at 300 DPI is US Letter: 8.5 × 11 in, 612 × 792 pt.
        let letter = try makeTestJPEG(width: 2550, height: 3300)
        let url = folder.appendingPathComponent("Scan.pdf")

        try writer.write(pages: [letter], dpi: 300, to: url, as: .pdf, append: false)
        try writer.write(pages: [letter], dpi: 300, to: url, as: .pdf, append: true)

        XCTAssertEqual(try pageSizes(at: url), [
            CGSize(width: 612, height: 792), CGSize(width: 612, height: 792)
        ])
    }

    // MARK: Encoder and FileType

    func testUndecodablePageFailsInsteadOfWritingGarbage() {
        let garbage = Data("not a jpeg".utf8)
        for type in [FileType.png, .tiff, .pdf] {
            XCTAssertThrowsError(try FileDestinationWriter.encode(pages: [garbage], dpi: 300, as: type))
        }
    }

    func testTruncatedJPEGFailsInsteadOfCrashingPDFAssembly() {
        // Has a JPEG header, so it looks like an image until it is decoded.
        XCTAssertThrowsError(try FileDestinationWriter.encode(pages: [Fixtures.minimalJPEG], dpi: 300, as: .pdf))
    }

    func testEncodingNoPagesFails() {
        for type in [FileType.png, .tiff, .jpeg] {
            XCTAssertThrowsError(try FileDestinationWriter.encode(pages: [], dpi: 300, as: type))
        }
    }

    func testFileTypeExtensionsAndDisplayNames() {
        XCTAssertEqual(FileType.allCases, [.pdf, .png, .jpeg, .tiff])
        XCTAssertEqual(FileType.allCases.map(\.fileExtension), ["pdf", "png", "jpg", "tiff"])
        XCTAssertEqual(FileType.allCases.map(\.displayName), ["PDF", "PNG", "JPEG", "TIFF"])
    }

    // MARK: Helpers

    /// The media box size of every page, rounded to whole points.
    private func pageSizes(at url: URL) throws -> [CGSize] {
        let document = try XCTUnwrap(PDFDocument(url: url))
        return (0..<document.pageCount).compactMap { index in
            document.page(at: index).map { page in
                let size = page.bounds(for: .mediaBox).size
                return CGSize(width: size.width.rounded(), height: size.height.rounded())
            }
        }
    }

    /// Every entry in the test folder, hidden ones included.
    private func folderContents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    /// A one-page PDF fixture written with PDFKit's own encryption options.
    private func writeProtectedPDF(to url: URL, options: [PDFDocumentWriteOption: Any]) throws {
        let data = try FileDestinationWriter.encode(
            pages: [try makeTestJPEG(width: 40, height: 30)], dpi: 300, as: .pdf
        )
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertTrue(document.write(to: url, withOptions: options))
    }
}
