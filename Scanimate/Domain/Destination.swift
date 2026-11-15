import Foundation

/// The file type a Destination writes a ScanResult as.
enum FileType: String, CaseIterable, Codable, Sendable {
    case pdf
    case png
    case jpeg
    case tiff

    /// The filename extension, without the leading dot.
    var fileExtension: String {
        switch self {
        case .pdf: return "pdf"
        case .png: return "png"
        case .jpeg: return "jpg"
        case .tiff: return "tiff"
        }
    }

    /// Every extension a user might type for this file type, lowercased.
    var recognizedExtensions: [String] {
        switch self {
        case .pdf: return ["pdf"]
        case .png: return ["png"]
        case .jpeg: return ["jpg", "jpeg"]
        case .tiff: return ["tiff", "tif"]
        }
    }

    var displayName: String {
        switch self {
        case .pdf: return "PDF"
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .tiff: return "TIFF"
        }
    }
}

/// Where a ScanJob's ScanResult is written: a name, a file type, a folder and
/// an append flag. Set inline before scanning and applied the moment the
/// ScanJob completes.
struct Destination: Equatable, Sendable {
    static let defaultName = "Scan"

    /// The name as the user typed it. See `baseName` for the name actually used.
    var name: String
    var fileType: FileType
    /// Nil until the user chooses a folder; it is chosen again on every launch.
    var folder: URL?
    /// Add the ScanResult's pages to the end of the PDF already at the name,
    /// instead of creating a file. Only means something when the file type is PDF.
    var append: Bool = false

    /// True when a write adds to an existing PDF: append is set and the file
    /// type is PDF. The flag is ignored for every other file type.
    var appendsToPDF: Bool { append && fileType == .pdf }

    /// The name without surrounding whitespace and without a typed extension
    /// that matches the file type (`Scan.PDF` as PDF is `Scan`).
    var baseName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        for ext in fileType.recognizedExtensions where lowercased.hasSuffix("." + ext) {
            return String(trimmed.dropLast(ext.count + 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    /// What writing a ScanResult to this Destination will do right now.
    ///
    /// Pure: the only views of the disk are `fileExists` and `appendTarget`.
    /// The caption and the write both go through here, so they cannot disagree.
    ///
    /// Without append, an existing file is never the target — the name is
    /// incremented (`Scan 2`, `Scan 3`, …) to the first one not taken. With
    /// append, the file at the name is the target and the name is never
    /// incremented: `appendTarget` says whether that file can be added to, and
    /// is only asked about a file that exists.
    func plan(fileExists: (URL) -> Bool, appendTarget: (URL) -> PDFAppendTarget) -> DestinationPlan {
        guard let folder else { return .blocked(.noFolder) }
        let base = baseName
        guard !base.isEmpty else { return .blocked(.emptyName) }
        guard !base.contains("/"), !base.contains(":") else { return .blocked(.invalidName) }

        func url(named name: String) -> URL {
            folder.appendingPathComponent("\(name).\(fileType.fileExtension)", isDirectory: false)
        }

        let wanted = url(named: base)
        if appendsToPDF {
            guard fileExists(wanted) else { return .createForAppend(wanted) }
            switch appendTarget(wanted) {
            case .appendable(let pageCount):
                return .append(wanted, existingPageCount: pageCount)
            case .protected:
                return .blocked(.appendTargetProtected(wanted))
            case .unusable:
                return .blocked(.appendTargetUnusable(wanted))
            }
        }

        guard fileExists(wanted) else { return .create(wanted) }

        var counter = 2
        while true {
            let candidate = url(named: "\(base) \(counter)")
            if !fileExists(candidate) {
                return .createIncremented(candidate, taken: wanted)
            }
            counter += 1
        }
    }
}

/// Whether the existing file at a Destination's path can have pages added to it.
enum PDFAppendTarget: Equatable, Sendable {
    /// A readable, writable, unprotected PDF holding `pageCount` pages.
    case appendable(pageCount: Int)
    /// A PDF that is password-protected, encrypted, or forbids document assembly.
    case protected
    /// Not a PDF, not a regular file, unreadable, or read-only.
    case unusable
}

/// The outcome of planning a write to a Destination.
enum DestinationPlan: Equatable, Sendable {
    /// Nothing is at the URL; the file is created there.
    case create(URL)
    /// `taken` already exists, so the file is created at the incremented URL instead.
    case createIncremented(URL, taken: URL)
    /// Append is set but nothing is at the URL yet; the file is created there.
    case createForAppend(URL)
    /// The pages are added to the end of the PDF at the URL, which holds
    /// `existingPageCount` pages now.
    case append(URL, existingPageCount: Int)
    /// The Destination cannot be written to; a ScanJob must not start.
    case blocked(BlockedReason)

    enum BlockedReason: Equatable, Sendable {
        case noFolder
        case emptyName
        /// The name contains `/` or `:`.
        case invalidName
        /// Append is set and the file at the URL is a protected PDF.
        case appendTargetProtected(URL)
        /// Append is set and the file at the URL is not a PDF that can be
        /// opened and rewritten.
        case appendTargetUnusable(URL)
    }

    /// The URL the write will create or add to, or nil when blocked.
    var url: URL? {
        switch self {
        case .create(let url), .createIncremented(let url, _),
             .createForAppend(let url), .append(let url, _):
            return url
        case .blocked:
            return nil
        }
    }

    /// True when the write is made in append mode, so it adds to a PDF at the
    /// URL and never increments the name.
    var isAppend: Bool {
        switch self {
        case .createForAppend, .append: return true
        case .create, .createIncremented, .blocked: return false
        }
    }

    var isBlocked: Bool { url == nil }

    /// One sentence saying exactly what the next scan will write, or why it cannot.
    var caption: String {
        switch self {
        case .create(let url):
            return "Will create \(url.lastPathComponent)"
        case .createIncremented(let url, let taken):
            return "\(taken.lastPathComponent) exists. Will save as \(url.lastPathComponent)"
        case .createForAppend(let url):
            return "\(url.lastPathComponent) doesn't exist yet. Will create it"
        case .append(let url, let existingPageCount):
            return "Will add to \(url.lastPathComponent) (\(Self.pageCountText(existingPageCount)))"
        case .blocked(.appendTargetProtected(let url)):
            return Self.protectedMessage(for: url)
        case .blocked(.appendTargetUnusable(let url)):
            return Self.unusableMessage(for: url)
        case .blocked(.noFolder):
            return "Choose a folder to enable Scan."
        case .blocked(.emptyName):
            return "Enter a file name."
        case .blocked(.invalidName):
            return "A file name can't contain / or :"
        }
    }

    /// "1 page", "3 pages".
    static func pageCountText(_ count: Int) -> String {
        count == 1 ? "1 page" : "\(count) pages"
    }

    /// Why a protected PDF blocks an append. Shared by the caption and the
    /// writer's error, so both say the same thing.
    static func protectedMessage(for url: URL) -> String {
        "\(url.lastPathComponent) is protected and can't be added to"
    }

    /// Why a file that is not a usable PDF blocks an append.
    static func unusableMessage(for url: URL) -> String {
        "\(url.lastPathComponent) can't be opened as a PDF"
    }
}
