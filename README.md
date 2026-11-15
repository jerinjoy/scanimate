<p align="center">
  <img src="docs/icon.png" width="128" alt="Scanimate icon">
</p>

<h1 align="center">Scanimate</h1>

<p align="center">Bringing old scanners back to life</p>

Scanimate is a macOS app for scanning from a **Samsung SL-M2070 series** network printer/scanner. Apple's Image Capture doesn't detect it. Scanimate talks to it directly over WSD (WS-Scan).

## Features

- **Find scanners** on your network automatically, or add one by IP and save it
- **Preview and crop**: run a quick preview of the flatbed, then drag out the area to scan
- **Document feeder** support: scans every sheet into a single PDF
- **Save automatically** as PDF, PNG, JPEG or TIFF to a folder you pick, with no save dialog
- **Build multi-page PDFs** by appending each new scan to an existing file

## Requirements

- macOS 13 or later
- A scanner on the same local network
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build

```bash
xcodegen generate
open Scanimate.xcodeproj
```

## More

- [`CONTEXT.md`](CONTEXT.md): domain language and behaviour
- [`docs/adr/`](docs/adr/): design decisions
