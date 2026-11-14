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

extension ScanRegion {
    /// Platen dimensions in WSD units (1/1000 inch): Letter, 8.5 in by 11 in.
    static let bedWidth = 8500
    static let bedHeight = 11000
    /// The smallest side a ScanRegion may have, in WSD units (0.5 in).
    static let minimumSide = 500

    /// The ScanRegion described by a drag on the Overview from `start` to
    /// `current`, both in the coordinate space of a view of `containerSize`
    /// that shows the whole Platen. The drag may run in any direction and may
    /// leave the view; the result is clamped to the Platen. Returns nil when
    /// either side comes out smaller than `minSize`, so a stray click is not
    /// a ScanRegion.
    static func fromDrag(
        start: CGPoint,
        current: CGPoint,
        containerSize: CGSize,
        minSize: Int = ScanRegion.minimumSide
    ) -> ScanRegion? {
        guard containerSize.width > 0, containerSize.height > 0 else { return nil }

        func wsd(_ value: CGFloat, extent: CGFloat, bed: Int) -> Int {
            let units = (value * CGFloat(bed) / extent).rounded()
            return Int(max(0, min(CGFloat(bed), units)))
        }

        let xa = wsd(start.x, extent: containerSize.width, bed: bedWidth)
        let xb = wsd(current.x, extent: containerSize.width, bed: bedWidth)
        let ya = wsd(start.y, extent: containerSize.height, bed: bedHeight)
        let yb = wsd(current.y, extent: containerSize.height, bed: bedHeight)

        let region = ScanRegion(
            xOffset: min(xa, xb),
            yOffset: min(ya, yb),
            width: abs(xa - xb),
            height: abs(ya - yb)
        )
        guard region.width >= minSize, region.height >= minSize else { return nil }
        return region
    }
}

struct ScanTicket: Codable {
    var resolution: Resolution
    var colorMode: ColorMode
    var paperSize: PaperSize
    var source: InputSource
    var scanRegion: ScanRegion?
}
