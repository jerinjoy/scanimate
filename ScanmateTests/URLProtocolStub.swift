import Foundation
@testable import Scanimate

// MARK: - URLProtocol stub

final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data?))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = URLProtocolStub.requestHandler else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

extension URLSession {
    static func stubbed() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: config)
    }
}

// MARK: - Fixture builder

enum Fixtures {
    // Minimal valid 1×1 JPEG
    static let minimalJPEG: Data = {
        // Standard 1×1 white JPEG bytes
        let bytes: [UInt8] = [
            0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
            0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43,
            0x00, 0x08, 0x06, 0x06, 0x07, 0x06, 0x05, 0x08, 0x07, 0x07, 0x07, 0x09,
            0x09, 0x08, 0x0A, 0x0C, 0x14, 0x0D, 0x0C, 0x0B, 0x0B, 0x0C, 0x19, 0x12,
            0x13, 0x0F, 0x14, 0x1D, 0x1A, 0x1F, 0x1E, 0x1D, 0x1A, 0x1C, 0x1C, 0x20,
            0x24, 0x2E, 0x27, 0x20, 0x22, 0x2C, 0x23, 0x1C, 0x1C, 0x28, 0x37, 0x29,
            0x2C, 0x30, 0x31, 0x34, 0x34, 0x34, 0x1F, 0x27, 0x39, 0x3D, 0x38, 0x32,
            0x3C, 0x2E, 0x33, 0x34, 0x32, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01,
            0x00, 0x01, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xC4, 0x00, 0x1F, 0x00, 0x00,
            0x01, 0x05, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
            0x09, 0x0A, 0x0B, 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F,
            0x00, 0xFB, 0xD7, 0xFF, 0xD9
        ]
        return Data(bytes)
    }()

    static func getScannerElementsResponse() -> Data {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
                    xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing"
                    xmlns:sca="http://schemas.microsoft.com/windows/2006/08/wdp/scan">
          <s:Header>
            <wsa:Action>http://schemas.microsoft.com/windows/2006/08/wdp/scan/GetScannerElementsResponse</wsa:Action>
          </s:Header>
          <s:Body>
            <sca:GetScannerElementsResponse>
              <sca:ScannerElements>
                <sca:ElementData Name="sca:ScannerStatus" Valid="true">
                  <sca:ScannerStatus>
                    <sca:ScannerState>Idle</sca:ScannerState>
                  </sca:ScannerStatus>
                </sca:ElementData>
              </sca:ScannerElements>
            </sca:GetScannerElementsResponse>
          </s:Body>
        </s:Envelope>
        """
        return Data(xml.utf8)
    }

    static func createScanJobResponse(jobId: String = "1", jobToken: String = "TOKEN123") -> Data {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
                    xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing"
                    xmlns:sca="http://schemas.microsoft.com/windows/2006/08/wdp/scan">
          <s:Header>
            <wsa:Action>http://schemas.microsoft.com/windows/2006/08/wdp/scan/CreateScanJobResponse</wsa:Action>
          </s:Header>
          <s:Body>
            <sca:CreateScanJobResponse>
              <sca:JobId>\(jobId)</sca:JobId>
              <sca:JobToken>\(jobToken)</sca:JobToken>
            </sca:CreateScanJobResponse>
          </s:Body>
        </s:Envelope>
        """
        return Data(xml.utf8)
    }

    static func retrieveImageResponse(jpeg: Data = Fixtures.minimalJPEG) -> (contentType: String, body: Data) {
        let boundary = "uuid:test-boundary-abc123"
        let soapPart = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
                    xmlns:sca="http://schemas.microsoft.com/windows/2006/08/wdp/scan">
          <s:Body>
            <sca:RetrieveImageResponse/>
          </s:Body>
        </s:Envelope>
        """

        var body = Data()
        let nl = "\r\n"
        body.append(Data("--\(boundary)\(nl)".utf8))
        body.append(Data("Content-Type: application/xop+xml; charset=UTF-8; type=\"application/soap+xml\"\(nl)".utf8))
        body.append(Data("Content-Transfer-Encoding: 8bit\(nl)\(nl)".utf8))
        body.append(Data(soapPart.utf8))
        body.append(Data("\(nl)--\(boundary)\(nl)".utf8))
        body.append(Data("Content-Type: image/jpeg\(nl)".utf8))
        body.append(Data("Content-Transfer-Encoding: binary\(nl)\(nl)".utf8))
        body.append(jpeg)
        body.append(Data("\(nl)--\(boundary)--\(nl)".utf8))

        let contentType = "multipart/related; boundary=\"\(boundary)\"; type=\"application/xop+xml\""
        return (contentType, body)
    }

    static func busyFaultResponse() -> Data {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
          <s:Body>
            <s:Fault>
              <s:Code><s:Value>s:Receiver</s:Value></s:Code>
              <s:Reason><s:Text xml:lang="en">ServiceUnavailable: printer busy</s:Text></s:Reason>
            </s:Fault>
          </s:Body>
        </s:Envelope>
        """
        return Data(xml.utf8)
    }

    static func noDocumentCreateJobResponse() -> Data {
        // CreateScanJob succeeds but returns no JobId
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
                    xmlns:sca="http://schemas.microsoft.com/windows/2006/08/wdp/scan">
          <s:Body>
            <sca:CreateScanJobResponse>
              <sca:JobId></sca:JobId>
            </sca:CreateScanJobResponse>
          </s:Body>
        </s:Envelope>
        """
        return Data(xml.utf8)
    }

    static func adfDoneResponse() -> Data {
        // A non-multipart response with no JPEG — signals ADF feeder empty
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
                    xmlns:sca="http://schemas.microsoft.com/windows/2006/08/wdp/scan">
          <s:Body>
            <s:Fault>
              <s:Code><s:Value>s:Sender</s:Value></s:Code>
              <s:Reason><s:Text xml:lang="en">NoDocument</s:Text></s:Reason>
            </s:Fault>
          </s:Body>
        </s:Envelope>
        """
        return Data(xml.utf8)
    }
}

// MARK: - Thread-safe state collector for tests

actor StateCollector {
    private var _values: [Int] = []

    func add(_ value: Int) {
        _values.append(value)
    }

    var values: [Int] { _values }
}

// MARK: - URLRequest body helper

extension URLRequest {
    var resolvedBodyData: Data? {
        if let body = httpBody { return body }
        guard let stream = httpBodyStream else { return nil }
        var data = Data()
        stream.open()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate(); stream.close() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count > 0 { data.append(buffer, count: count) }
        }
        return data
    }
}

// MARK: - Convenience HTTP response builder

extension HTTPURLResponse {
    static func ok(url: URL = URL(string: "http://192.168.1.66:8018/wsd/scan")!,
                   contentType: String = "application/soap+xml") -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": contentType]
        )!
    }

    static func status(_ code: Int, url: URL = URL(string: "http://192.168.1.66:8018/wsd/scan")!) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
    }
}
