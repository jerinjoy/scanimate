import Foundation

struct ScannerTarget: Identifiable, Equatable, Codable, Hashable {
    enum Source: String, Codable, Equatable, Hashable {
        case discovered
        case manual
    }

    let host: String
    var displayName: String?
    let source: Source

    var id: String { host }
}
