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

## Install

1. Download `Scanimate-<version>.zip` from the [latest release](https://github.com/jerinjoy/scanimate/releases/latest) and unzip it.
2. Move `Scanimate.app` to your Applications folder.
3. Open it. macOS will refuse, because the app is not notarized by Apple.
4. Go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**.

Step 4 is only needed the first time. If you prefer the terminal, this does the same thing:

```bash
xattr -dr com.apple.quarantine /Applications/Scanimate.app
```

Scanimate asks for Local Network access on first launch. It needs that to reach the scanner.

## Build from source

Needs Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
xcodegen generate
open Scanimate.xcodeproj
```

To build the release zip, run `scripts/release.sh`. It writes `build/Scanimate-<version>.zip`.

## More

- [`CONTEXT.md`](CONTEXT.md): domain language and behaviour
- [`docs/adr/`](docs/adr/): design decisions
