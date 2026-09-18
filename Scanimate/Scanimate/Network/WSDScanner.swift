import Foundation

// MARK: - Protocol for testability

protocol WSDScannerProtocol: Sendable {
    func scan(
        ticket: ScanTicket,
        onState: @Sendable (ScanJob) async -> Void
    ) async throws -> [Data]
}

// MARK: - Actor

actor WSDScanner: WSDScannerProtocol {
    let host: String
    private(set) var activeJobId: String?

    private let session: URLSession
    private let retryPauseNanoseconds: UInt64

    static let wsdPort = 8018
    static let wsdPath = "/wsd/scan"
    static let nsSoap = "http://www.w3.org/2003/05/soap-envelope"
    static let nsWsa  = "http://schemas.xmlsoap.org/ws/2004/08/addressing"
    static let nsScan = "http://schemas.microsoft.com/windows/2006/08/wdp/scan"
    static let wsaAnon = "http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous"

    private let clientUrn = "urn:uuid:\(UUID().uuidString.lowercased())"

    private var baseURL: String {
        "http://\(host):\(WSDScanner.wsdPort)\(WSDScanner.wsdPath)"
    }

    init(host: String, session: URLSession = .shared, retryPauseNanoseconds: UInt64 = 1_000_000_000) {
        self.host = host
        self.session = session
        self.retryPauseNanoseconds = retryPauseNanoseconds
    }

    // MARK: - Public scan method

    func scan(
        ticket: ScanTicket,
        onState: @Sendable (ScanJob) async -> Void
    ) async throws -> [Data] {
        await onState(.checkingScanner)
        _ = try await getScannerElements()
        try Task.checkCancellation()

        let (jobId, jobToken) = try await createScanJob(ticket: ticket, onState: onState)
        activeJobId = jobId
        try Task.checkCancellation()

        var pages: [Data] = []
        do {
            if ticket.source == .adf {
                var pageNum = 1
                while true {
                    try Task.checkCancellation()
                    await onState(.retrievingPage(pageNum))
                    do {
                        let data = try await retrieveImage(jobId: jobId, jobToken: jobToken)
                        pages.append(data)
                        pageNum += 1
                    } catch ScanError.noDocument where !pages.isEmpty {
                        break
                    }
                }
            } else {
                await onState(.retrievingPage(1))
                let data = try await retrieveImage(jobId: jobId, jobToken: jobToken)
                pages.append(data)
            }
        } catch is CancellationError {
            await cancelJob()
            throw CancellationError()
        } catch {
            throw error
        }

        activeJobId = nil
        return pages
    }

    // MARK: - WSD operations

    private func getScannerElements() async throws -> String {
        let action = "\(WSDScanner.nsScan)/GetScannerElements"
        let body = """
            <sca:GetScannerElementsRequest>
              <sca:RequestedElements>
                <sca:Name>sca:ScannerStatus</sca:Name>
              </sca:RequestedElements>
            </sca:GetScannerElementsRequest>
        """
        let (_, data) = try await soapPost(action: action, body: body, timeout: 30)
        let xml = try parseXML(data)
        let state = xmlText(xml, local: "ScannerState") ?? "Unknown"
        if state.lowercased() != "idle" {
            NSLog("WSDScanner: scanner state is '%@' — proceeding anyway", state)
        }
        return state
    }

    private func createScanJob(
        ticket: ScanTicket,
        onState: @Sendable (ScanJob) async -> Void
    ) async throws -> (String, String) {
        let action = "\(WSDScanner.nsScan)/CreateScanJob"
        let body = scanJobBody(ticket: ticket)

        for attempt in 1...30 {
            await onState(.creatingJob(attempt: attempt))
            try Task.checkCancellation()

            do {
                let (_, data) = try await soapPost(action: action, body: body, timeout: 30)
                let xml = try parseXML(data)
                guard let jobId = xmlText(xml, local: "JobId"), !jobId.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw ScanError.noDocument
                }
                let jobToken = xmlText(xml, local: "JobToken") ?? ""
                return (jobId.trimmingCharacters(in: .whitespaces), jobToken.trimmingCharacters(in: .whitespaces))
            } catch ScanError.printerBusy {
                if attempt == 30 { throw ScanError.printerBusy }
                try await Task.sleep(nanoseconds: retryPauseNanoseconds)
                continue
            }
        }
        throw ScanError.printerBusy
    }

    private func retrieveImage(jobId: String, jobToken: String) async throws -> Data {
        let action = "\(WSDScanner.nsScan)/RetrieveImage"
        let body = """
            <sca:RetrieveImageRequest>
              <sca:JobId>\(jobId)</sca:JobId>
              <sca:JobToken>\(jobToken)</sca:JobToken>
              <sca:DocumentDescription>
                <sca:DocumentName>IMAGE000.JPG</sca:DocumentName>
              </sca:DocumentDescription>
            </sca:RetrieveImageRequest>
        """
        let (headers, data) = try await soapPost(action: action, body: body, timeout: 90)
        return try extractJpegFromMTOM(headers: headers, data: data)
    }

    func cancelJob() async {
        guard let jobId = activeJobId else { return }
        activeJobId = nil
        let action = "\(WSDScanner.nsScan)/CancelJob"
        let body = """
            <sca:CancelJobRequest>
              <sca:JobId>\(jobId)</sca:JobId>
            </sca:CancelJobRequest>
        """
        let envelope = soapEnvelope(action: action, body: body)
        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.httpBody = envelope.data(using: .utf8)
        setBaseHeaders(on: &request)
        request.timeoutInterval = 10
        _ = try? await session.data(for: request)
    }

    // MARK: - HTTP transport

    private func soapPost(
        action: String,
        body: String,
        timeout: TimeInterval
    ) async throws -> ([String: String], Data) {
        let envelope = soapEnvelope(action: action, body: body)
        let encoded = envelope.data(using: .utf8) ?? Data()

        guard let url = URL(string: baseURL) else {
            throw ScanError.protocolError("Invalid URL: \(baseURL)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = encoded
        setBaseHeaders(on: &request)
        request.timeoutInterval = timeout

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ScanError.protocolError("Non-HTTP response")
            }

            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let k = key as? String, let v = value as? String {
                    headers[k.lowercased()] = v
                }
            }

            switch http.statusCode {
            case 200, 202:
                return (headers, data)
            case 400:
                throw ScanError.protocolError(
                    "HTTP 400 — possible namespace mismatch. Body: \(String(data: data.prefix(200), encoding: .utf8) ?? "")"
                )
            case 503:
                throw ScanError.printerBusy
            default:
                throw mapSoapFault(status: http.statusCode, data: data)
            }
        } catch let error as ScanError {
            throw error
        } catch let urlError as URLError {
            switch urlError.code {
            case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet,
                 .timedOut, .cannotFindHost, .dnsLookupFailed:
                throw ScanError.unreachable(host: host)
            default:
                throw ScanError.unreachable(host: host)
            }
        } catch {
            throw ScanError.protocolError(error.localizedDescription)
        }
    }

    private func setBaseHeaders(on request: inout URLRequest) {
        request.setValue("application/soap+xml", forHTTPHeaderField: "Content-Type")
        request.setValue("WSDAPI", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
    }

    // MARK: - SOAP envelope builder

    private func soapEnvelope(action: String, body: String) -> String {
        let msgId = "urn:uuid:\(UUID().uuidString.lowercased())"
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <soap:Envelope xmlns:soap="\(WSDScanner.nsSoap)" xmlns:wsa="\(WSDScanner.nsWsa)" xmlns:sca="\(WSDScanner.nsScan)">
          <soap:Header>
            <wsa:To>\(baseURL)</wsa:To>
            <wsa:Action>\(action)</wsa:Action>
            <wsa:MessageID>\(msgId)</wsa:MessageID>
            <wsa:ReplyTo><wsa:Address>\(WSDScanner.wsaAnon)</wsa:Address></wsa:ReplyTo>
            <wsa:From><wsa:Address>\(clientUrn)</wsa:Address></wsa:From>
          </soap:Header>
          <soap:Body>
        \(body)
          </soap:Body>
        </soap:Envelope>
        """
    }

    private func scanJobBody(ticket: ScanTicket) -> String {
        let w = ticket.paperSize.width
        let h = ticket.paperSize.height
        let imagesToTransfer = ticket.source == .adf ? 0 : 1
        return """
            <sca:CreateScanJobRequest>
              <sca:ScanTicket>
                <sca:JobDescription>
                  <sca:JobName>ScanimateScan</sca:JobName>
                  <sca:JobOriginatingUserName>user</sca:JobOriginatingUserName>
                </sca:JobDescription>
                <sca:DocumentParameters>
                  <sca:Format>jfif</sca:Format>
                  <sca:CompressionQualityFactor>85</sca:CompressionQualityFactor>
                  <sca:ImagesToTransfer>\(imagesToTransfer)</sca:ImagesToTransfer>
                  <sca:InputSource>\(ticket.source.rawValue)</sca:InputSource>
                  <sca:ContentType>Auto</sca:ContentType>
                  <sca:InputSize>
                    <sca:DocumentSizeAutoDetect>false</sca:DocumentSizeAutoDetect>
                    <sca:InputMediaSize>
                      <sca:Width>\(w)</sca:Width>
                      <sca:Height>\(h)</sca:Height>
                    </sca:InputMediaSize>
                  </sca:InputSize>
                  <sca:Exposure><sca:AutoExposure>true</sca:AutoExposure></sca:Exposure>
                  <sca:Scaling>
                    <sca:ScalingWidth>100</sca:ScalingWidth>
                    <sca:ScalingHeight>100</sca:ScalingHeight>
                  </sca:Scaling>
                  <sca:MediaSides>
                    <sca:MediaFront>
                      <sca:ScanRegion>
                        <sca:ScanRegionXOffset>0</sca:ScanRegionXOffset>
                        <sca:ScanRegionYOffset>0</sca:ScanRegionYOffset>
                        <sca:ScanRegionWidth>\(w)</sca:ScanRegionWidth>
                        <sca:ScanRegionHeight>\(h)</sca:ScanRegionHeight>
                      </sca:ScanRegion>
                      <sca:ColorProcessing>\(ticket.colorMode.rawValue)</sca:ColorProcessing>
                      <sca:Resolution>
                        <sca:Width>\(ticket.resolution.rawValue)</sca:Width>
                        <sca:Height>\(ticket.resolution.rawValue)</sca:Height>
                      </sca:Resolution>
                    </sca:MediaFront>
                  </sca:MediaSides>
                </sca:DocumentParameters>
              </sca:ScanTicket>
            </sca:CreateScanJobRequest>
        """
    }

    // MARK: - MTOM parser

    private func extractJpegFromMTOM(headers: [String: String], data: Data) throws -> Data {
        let contentType = headers["content-type"] ?? ""
        guard contentType.lowercased().contains("multipart") else {
            return data
        }

        guard let boundaryRange = contentType.range(of: #"boundary=(?:"([^"]+)"|([^\s;]+))"#, options: .regularExpression) else {
            throw ScanError.protocolError("MTOM Content-Type has no boundary parameter")
        }

        let boundaryStr = String(contentType[boundaryRange])
        let boundary: String
        if let quotedRange = boundaryStr.range(of: #"boundary="([^"]+)""#, options: .regularExpression) {
            let quoted = String(boundaryStr[quotedRange])
            boundary = String(quoted.dropFirst(10).dropLast(1))
        } else {
            boundary = String(boundaryStr.dropFirst(9))
        }

        let delimiter = ("--" + boundary).data(using: .utf8)!
        let parts = splitMTOM(data: data, delimiter: delimiter)

        guard parts.count >= 2 else {
            throw ScanError.noDocument
        }
        return stripPartHeaders(parts[1])
    }

    private func splitMTOM(data: Data, delimiter: Data) -> [Data] {
        var segments: [Data] = []
        var searchStart = data.startIndex
        while let range = data.range(of: delimiter, in: searchStart..<data.endIndex) {
            segments.append(data[searchStart..<range.lowerBound])
            searchStart = range.upperBound
        }
        segments.append(data[searchStart...])

        var parts: [Data] = []
        for seg in segments.dropFirst() {
            if seg.starts(with: Data("--".utf8)) { break }
            parts.append(seg)
        }
        return parts
    }

    private func stripPartHeaders(_ part: Data) -> Data {
        let doubleCRLF = Data("\r\n\r\n".utf8)
        let doubleNewline = Data("\n\n".utf8)
        if let range = part.range(of: doubleCRLF) {
            return Data(part[range.upperBound...]).trimming(Data("\r\n".utf8))
        }
        if let range = part.range(of: doubleNewline) {
            return Data(part[range.upperBound...]).trimming(Data("\n".utf8))
        }
        return part
    }

    // MARK: - XML parsing

    private func parseXML(_ data: Data) throws -> XMLElement {
        do {
            let doc = try XMLDocument(data: data)
            guard let root = doc.rootElement() else {
                throw ScanError.protocolError("Empty XML response")
            }
            return root
        } catch let scanError as ScanError {
            throw scanError
        } catch {
            throw ScanError.protocolError("Invalid XML: \(error.localizedDescription)")
        }
    }

    private func xmlText(_ element: XMLElement, local: String) -> String? {
        let ns = WSDScanner.nsScan
        if let el = element.elements(forLocalName: local, uri: ns).first {
            return el.stringValue
        }
        if let el = (element.children?.compactMap { $0 as? XMLElement }
            .flatMap { allDescendants($0) }
            .first { $0.localName == local }) {
            return el.stringValue
        }
        return nil
    }

    private func allDescendants(_ element: XMLElement) -> [XMLElement] {
        var result = [element]
        for child in element.children ?? [] {
            if let el = child as? XMLElement {
                result.append(contentsOf: allDescendants(el))
            }
        }
        return result
    }

    private func mapSoapFault(status: Int, data: Data) -> ScanError {
        guard let xml = try? XMLDocument(data: data),
              let root = xml.rootElement() else {
            return .protocolError("HTTP \(status)")
        }
        let body = String(data: data.prefix(400), encoding: .utf8) ?? ""
        if body.lowercased().contains("busy") || body.lowercased().contains("serviceunavailable") {
            return .printerBusy
        }
        if body.lowercased().contains("nodocument") || body.lowercased().contains("nopaper") {
            return .noDocument
        }
        let faultText = (root.elements(forLocalName: "Text", uri: WSDScanner.nsSoap).first?.stringValue)
            ?? "HTTP \(status)"
        return .protocolError(faultText)
    }
}

// MARK: - Data extension

private extension Data {
    func trimming(_ bytes: Data) -> Data {
        var result = self
        while result.starts(with: bytes) {
            result = result.dropFirst(bytes.count)
        }
        while result.hasSuffix(bytes) {
            result = result.dropLast(bytes.count)
        }
        return result
    }

    func hasSuffix(_ suffix: Data) -> Bool {
        guard count >= suffix.count else { return false }
        return self.suffix(suffix.count) == suffix
    }
}
