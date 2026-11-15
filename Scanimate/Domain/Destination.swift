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

/// Where a ScanJob's ScanResult is written: a name, a file type and a folder.
/// Set inline before scanning and applied the moment the ScanJob completes.
struct Destination: Equatable, Sendable {
    static let defaultName = "Scan"

    /// The name as the user typed it. See `baseName` for the name actually used.
    var name: String
    var fileType: FileType
    /// Nil until the user chooses a folder; it is chosen again on every launch.
    var folder: URL?

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
    /// Pure: the only view of the disk is `fileExists`. The caption and the
    /// write both go through here, so they cannot disagree. An existing file is
    /// never the target — the name is incremented (`Scan 2`, `Scan 3`, …) to
    /// the first one not taken.
    func plan(fileExists: (URL) -> Bool) -> DestinationPlan {
        guard let folder else { return .blocked(.noFolder) }
        let base = baseName
        guard !base.isEmpty else { return .blocked(.emptyName) }
        guard !base.contains("/"), !base.contains(":") else { return .blocked(.invalidName) }

        func url(named name: String) -> URL {
            folder.appendingPathComponent("\(name).\(fileType.fileExtension)", isDirectory: false)
        }

        let wanted = url(named: base)
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

/// The outcome of planning a write to a Destination.
enum DestinationPlan: Equatable, Sendable {
    /// Nothing is at the URL; the file is created there.
    case create(URL)
    /// `taken` already exists, so the file is created at the incremented URL instead.
    case createIncremented(URL, taken: URL)
    /// The Destination cannot be written to; a ScanJob must not start.
    case blocked(BlockedReason)

    enum BlockedReason: Equatable, Sendable {
        case noFolder
        case emptyName
        /// The name contains `/` or `:`.
        case invalidName
    }

    /// The URL the write will create, or nil when blocked.
    var url: URL? {
        switch self {
        case .create(let url), .createIncremented(let url, _): return url
        case .blocked: return nil
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
        case .blocked(.noFolder):
            return "Choose a folder to enable Scan."
        case .blocked(.emptyName):
            return "Enter a file name."
        case .blocked(.invalidName):
            return "A file name can't contain / or :"
        }
    }
}
