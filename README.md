# Scanimate
Bringing old scanners back to life

A macOS app that scans from a **Samsung SL-M2070 series** network MFP using the WSD protocol, without Apple's Image Capture / ICA framework (which doesn't detect this device).

## Requirements

- macOS 13.0 or later
- The printer must be on the local network and reachable by IP.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`

## Setup

```bash
xcodegen generate
open Scanimate.xcodeproj
```

## Protocol notes

The SL-M2070 exposes its scanner via **WSD (WS-Scan)** — SOAP 1.2 messages sent over plain HTTP to port 8018 (`http://<printer-ip>:8018/wsd/scan`). It does **not** support eSCL (Apple AirScan).

The scan sequence is three SOAP calls:

1. **`GetScannerElements`** — checks scanner state and capabilities.
2. **`CreateScanJob`** — sends a `ScanTicket` XML with DPI, color mode, paper size, and returns a `JobId` + `JobToken`.
3. **`RetrieveImage`** — streams the scanned image back as a JPEG wrapped in an MTOM (multipart MIME) HTTP response.

The XML namespace for all scan operations is `http://schemas.microsoft.com/windows/2006/08/wdp/scan` (the `08` date variant — real devices return HTTP 400 for the `01` variant). Image dimensions in the `ScanTicket` are in thousandths of an inch (letter = 8500 × 11000).

Primary sources: [sane-airscan](https://github.com/alexpevzner/sane-airscan), [PyWSD](https://github.com/roncapat/WSD-python), [Microsoft WSD Scan spec](https://learn.microsoft.com/en-us/windows-hardware/drivers/image/).
