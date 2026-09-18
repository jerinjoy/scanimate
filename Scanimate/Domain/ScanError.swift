import Foundation

enum ScanError: Error, LocalizedError, Equatable {
    case unreachable(host: String)
    case printerBusy
    case noDocument
    case protocolError(String)

    var errorDescription: String? {
        switch self {
        case .unreachable(let host):
            return "Cannot reach \(host) — is the printer on and connected to the network?"
        case .printerBusy:
            return "The printer is busy — try again in a moment."
        case .noDocument:
            return "No document detected — place a page on the glass or load the ADF and try again."
        case .protocolError(let detail):
            return "Protocol error: \(detail)"
        }
    }
}
