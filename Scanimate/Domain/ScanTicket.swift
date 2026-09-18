import Foundation

enum Resolution: String, CaseIterable, Codable {
    case dpi75 = "75"
    case dpi150 = "150"
    case dpi300 = "300"
    case dpi600 = "600"

    var displayName: String { "\(rawValue) DPI" }
}

enum ColorMode: String, CaseIterable, Codable {
    case grayscale = "Grayscale8"
    case blackAndWhite = "BlackAndWhite1"
    case color = "RGB24"

    var displayName: String {
        switch self {
        case .grayscale: return "Grayscale"
        case .blackAndWhite: return "Black & White"
        case .color: return "Color"
        }
    }
}

enum PaperSize: String, CaseIterable, Codable {
    case letter
    case a4
    case legal

    var dimensions: (width: Int, height: Int) {
        switch self {
        case .letter: return (8500, 11000)
        case .a4: return (8268, 11693)
        case .legal: return (8500, 14000)
        }
    }

    var width: Int { dimensions.width }
    var height: Int { dimensions.height }

    var displayName: String {
        switch self {
        case .letter: return "Letter"
        case .a4: return "A4"
        case .legal: return "Legal"
        }
    }
}

enum InputSource: String, CaseIterable, Codable {
    case flatbed = "Platen"
    case adf = "ADF"

    var displayName: String {
        switch self {
        case .flatbed: return "Platen (Flatbed)"
        case .adf: return "ADF"
        }
    }
}

struct ScanRegion: Equatable, Codable {
    var xOffset: Int
    var yOffset: Int
    var width: Int
    var height: Int
}

struct ScanTicket: Codable {
    var resolution: Resolution
    var colorMode: ColorMode
    var paperSize: PaperSize
    var source: InputSource
    var scanRegion: ScanRegion?
}
