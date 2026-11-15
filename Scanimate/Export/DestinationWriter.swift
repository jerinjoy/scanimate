import AppKit
import ImageIO
import PDFKit

/// What a successful write to a Destination did.
enum DestinationWriteOutcome: Equatable, Sendable {
    /// A new file was created.
    case created
    /// Pages were added to an existing PDF, which now holds `totalPageCount`.
    case appended(addedPageCount: Int, totalPageCount: Int)
}

/// An append refused because of the file already at the Destination's path.
enum DestinationWriteError: LocalizedError, Equatable {
    /// The PDF is password-protected, encrypted, or forbids document assembly.
    case appendTargetProtected(URL)
    /// The file is not a PDF that can be opened and rewritten.
    case appendTargetUnusable(URL)

    var errorDescription: String? {
        switch self {
        case .appendTargetProtected(let url): return DestinationPlan.protectedMessage(for: url)
        case .appendTargetUnusable(let url): return DestinationPlan.unusableMessage(for: url)
        }
    }
}

/// The seam between the scan view model and the disk: everything needed to
/// write a ScanResult to a Destination. Injected into `ScanViewModel` next to
/// the scanner and discovery factories; tests replace it with an in-memory fake.
protocol DestinationWriter: Sendable {
    /// True when something already exists at `url`.
    func fileExists(at url: URL) -> Bool

    /// Whether the existing file at `url` can have pages added to it.
    func appendTarget(at url: URL) -> PDFAppendTarget

    /// Converts a ScanResult's raw JPEG `pages` to `fileType` and writes them to `url`.
    ///
    /// PDF holds every page. PNG, JPEG and TIFF hold a single image, so only
    /// the first page is written. JPEG is the Scanner's raw page data, byte for
    /// byte, with no re-encode. `dpi` is recorded in PNG and TIFF metadata and
    /// sizes each PDF page.
    ///
    /// Without `append`, a file already at `url` is never overwritten: the write
    /// throws. With `append` and PDF, the pages are added to the end of the PDF
    /// at `url`, or the file is created when nothing is there; a file that
    /// cannot be added to makes the write throw and is left exactly as it was.
    /// `append` is ignored for every other file type.
    @discardableResult
    func write(pages: [Data], dpi: Int, to url: URL, as fileType: FileType, append: Bool) throws
        -> DestinationWriteOutcome
}

extension DestinationWriter {
    /// The page count of the PDF at `url`, or nil when the file is not a PDF
    /// that can be added to.
    func pdfPageCount(at url: URL) -> Int? {
        if case .appendable(let pageCount) = appendTarget(at: url) { return pageCount }
        return nil
    }
}

/// The production `DestinationWriter`: PNG/TIFF encode via `CGImageDestination`,
/// PDF assembly via PDFKit, JPEG passed through untouched, real disk I/O.
struct FileDestinationWriter: DestinationWriter {

    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func appendTarget(at url: URL) -> PDFAppendTarget {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true else { return .unusable }
        let target = Self.appendTarget(for: PDFDocument(url: url))
        guard case .appendable = target else { return target }
        // An append rewrites the file, so one that cannot be written is no target.
        guard FileManager.default.isWritableFile(atPath: url.path) else { return .unusable }
        return target
    }

    /// The document-level checks, shared with the in-memory fake: the PDF
    /// opened, is neither locked nor encrypted, and allows document assembly.
    static func appendTarget(for document: PDFDocument?) -> PDFAppendTarget {
        guard let document else { return .unusable }
        guard !document.isLocked, !document.isEncrypted, document.allowsDocumentAssembly else {
            return .protected
        }
        return .appendable(pageCount: document.pageCount)
    }

    @discardableResult
    func write(pages: [Data], dpi: Int, to url: URL, as fileType: FileType, append: Bool) throws
        -> DestinationWriteOutcome {
        if append, fileType == .pdf, fileExists(at: url) {
            return try appendToPDF(pages: pages, dpi: dpi, at: url)
        }

        let data = try Self.encode(pages: pages, dpi: dpi, as: fileType)
        // An existing file is never replaced, even one that appeared since planning.
        guard !fileExists(at: url) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
        }
        do {
            try data.write(to: url, options: .withoutOverwriting)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            throw error
        } catch {
            // Not atomic, so do not leave a partial file of ours behind.
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return .created
    }

    // MARK: - Append

    /// Adds `pages` to the end of the PDF at `url`.
    ///
    /// The checks behind the caption are run again here, because the file may
    /// have changed since. The result is written to a temporary file beside the
    /// original and swapped in only once it is complete, so a failure at any
    /// point leaves the original untouched.
    private func appendToPDF(pages: [Data], dpi: Int, at url: URL) throws -> DestinationWriteOutcome {
        switch appendTarget(at: url) {
        case .appendable: break
        case .protected: throw DestinationWriteError.appendTargetProtected(url)
        case .unusable: throw DestinationWriteError.appendTargetUnusable(url)
        }
        guard let document = PDFDocument(url: url) else {
            throw DestinationWriteError.appendTargetUnusable(url)
        }
        try Self.append(pages: pages, dpi: dpi, to: document)
        let totalPageCount = document.pageCount

        // In the same folder: the swap must stay on one volume, and the folder
        // is the one place the app is certain to have access to.
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp", isDirectory: false)
        do {
            guard document.write(to: temporary),
                  PDFDocument(url: temporary)?.pageCount == totalPageCount else {
                throw ScanError.protocolError("Could not write the pages to \(url.lastPathComponent)")
            }
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        return .appended(addedPageCount: pages.count, totalPageCount: totalPageCount)
    }

    /// Inserts one PDF page per raw JPEG page at the end of `document`, in order.
    /// Every page is built before any is inserted, so a bad page changes nothing.
    static func append(pages: [Data], dpi: Int, to document: PDFDocument) throws {
        let pdfPages = try pages.enumerated().map { index, jpeg in
            try makePDFPage(jpeg: jpeg, dpi: dpi, number: index + 1)
        }
        for page in pdfPages {
            document.insert(page, at: document.pageCount)
        }
    }

    // MARK: - Encoding

    /// The exact bytes `write` puts on disk for `pages` as `fileType`.
    /// Pure — touches no files — so a fake writer can produce the same bytes.
    static func encode(pages: [Data], dpi: Int, as fileType: FileType) throws -> Data {
        switch fileType {
        case .pdf:
            return try encodePDF(pages: pages, dpi: dpi)
        case .png:
            return try encodeImage(pages: pages, dpi: dpi, utType: "public.png")
        case .tiff:
            return try encodeImage(pages: pages, dpi: dpi, utType: "public.tiff")
        case .jpeg:
            guard let jpeg = pages.first else {
                throw ScanError.protocolError("No page to write")
            }
            return jpeg
        }
    }

    private static func encodeImage(pages: [Data], dpi: Int, utType: String) throws -> Data {
        guard let jpeg = pages.first,
              let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ScanError.protocolError("Could not decode JPEG for export")
        }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, utType as CFString, 1, nil) else {
            throw ScanError.protocolError("Could not create image destination")
        }

        let props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi
        ]
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ScanError.protocolError("Could not write image to disk")
        }
        return data as Data
    }

    private static func encodePDF(pages: [Data], dpi: Int) throws -> Data {
        let pdfDoc = PDFDocument()
        try append(pages: pages, dpi: dpi, to: pdfDoc)

        guard let data = pdfDoc.dataRepresentation() else {
            throw ScanError.protocolError("Could not write PDF to disk")
        }
        return data
    }

    /// One PDF page showing `jpeg` at its physical size.
    ///
    /// `PDFPage(image:)` sizes the page from `NSImage.size`, which comes from
    /// the JPEG's density metadata and falls back to one point per pixel when
    /// there is none. The size is set from the ScanTicket's resolution instead
    /// (pixels × 72 ÷ DPI), so a 300 DPI Letter page is 612 × 792 pt whatever
    /// the Scanner wrote in the JPEG header.
    private static func makePDFPage(jpeg: Data, dpi: Int, number: Int) throws -> PDFPage {
        // Decode first: NSImage accepts a truncated JPEG lazily, and PDFKit
        // then crashes on it instead of failing.
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let nsImage = NSImage(data: jpeg) else {
            throw ScanError.protocolError("Could not create PDF page \(number)")
        }
        if dpi > 0 {
            let scale = 72.0 / CGFloat(dpi)
            nsImage.size = NSSize(width: CGFloat(cgImage.width) * scale, height: CGFloat(cgImage.height) * scale)
        }
        guard let page = PDFPage(image: nsImage) else {
            throw ScanError.protocolError("Could not create PDF page \(number)")
        }
        return page
    }
}
