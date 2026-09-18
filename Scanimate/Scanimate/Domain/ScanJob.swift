import Foundation

enum ScanJob {
    case checkingScanner
    case creatingJob(attempt: Int)
    case retrievingPage(Int)
    case complete([Data])
    case failed(ScanError)
    case cancelled
}
