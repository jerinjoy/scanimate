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

    var displayName: String {
        switch self {
        case .pdf: return "PDF"
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .tiff: return "TIFF"
        }
    }
}
