import AppKit
import ImageIO
import PDFKit

/// The seam between the scan view model and the disk: everything needed to
/// write a ScanResult to a Destination. Injected into `ScanViewModel` next to
/// the scanner and discovery factories; tests replace it with an in-memory fake.
protocol DestinationWriter: Sendable {
    /// True when something already exists at `url`.
    func fileExists(at url: URL) -> Bool

    /// The page count of the PDF at `url`, or nil when the file is not a PDF
    /// that can be added to.
    func pdfPageCount(at url: URL) -> Int?

    /// Converts a ScanResult's raw JPEG `pages` to `fileType` and writes them to `url`.
    ///
    /// PDF holds every page. PNG and TIFF hold a single image, so only the
    /// first page is written. `dpi` is recorded in the image metadata.
    /// With `append`, the pages are added to the end of an existing PDF at `url`.
    func write(pages: [Data], dpi: Int, to url: URL, as fileType: FileType, append: Bool) throws
}

/// The production `DestinationWriter`: PNG/TIFF encode via `CGImageDestination`,
/// PDF assembly via PDFKit, real disk I/O.
struct FileDestinationWriter: DestinationWriter {

    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func pdfPageCount(at url: URL) -> Int? {
        PDFDocument(url: url)?.pageCount
    }

    func write(pages: [Data], dpi: Int, to url: URL, as fileType: FileType, append: Bool) throws {
        // `append` is not honoured yet; every write creates the file.
        let data = try Self.encode(pages: pages, dpi: dpi, as: fileType)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Encoding

    /// The exact bytes `write` puts on disk for `pages` as `fileType`.
    /// Pure — touches no files — so a fake writer can produce the same bytes.
    static func encode(pages: [Data], dpi: Int, as fileType: FileType) throws -> Data {
        switch fileType {
        case .pdf:
            return try encodePDF(pages: pages)
        case .png:
            return try encodeImage(pages: pages, dpi: dpi, utType: "public.png")
        case .tiff:
            return try encodeImage(pages: pages, dpi: dpi, utType: "public.tiff")
        case .jpeg:
            throw ScanError.protocolError("JPEG output is not supported yet")
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

    private static func encodePDF(pages: [Data]) throws -> Data {
        let pdfDoc = PDFDocument()

        for (index, jpeg) in pages.enumerated() {
            guard let nsImage = NSImage(data: jpeg),
                  let page = PDFPage(image: nsImage) else {
                throw ScanError.protocolError("Could not create PDF page \(index + 1)")
            }
            pdfDoc.insert(page, at: pdfDoc.pageCount)
        }

        guard let data = pdfDoc.dataRepresentation() else {
            throw ScanError.protocolError("Could not write PDF to disk")
        }
        return data
    }
}
