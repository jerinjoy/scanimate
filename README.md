# scanimate
Bringing old scanners back to life

CLI tool to scan from a **Samsung SL-M2070 series** network MFP on macOS, without Apple's Image Capture / ICA framework (which doesn't support this device).

## Requirements

- [uv](https://docs.astral.sh/uv/) — `brew install uv`
- The printer must be on the local network and reachable by IP.

## Setup

```bash
uv sync
```

## Usage

```
uv run samsung-scanner --host <PRINTER_IP> --output scan.png
```

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `--host IP` | *(required)* | Printer IP address |
| `--output FILE` | *(required)* | Output path — `.png`, `.tif`, or `.tiff` |
| `--dpi N` | `300` | Resolution: 75, 150, 200, 300, or 600 |
| `--grayscale` | *(default)* | Grayscale scan |
| `--color` | | RGB color mode *(M2070 is monochrome — output will still be gray)* |
| `--bw` | | Black & white (1-bit) |
| `--paper SIZE` | `letter` | `letter`, `a4`, or `legal` |
| `--source SRC` | `Platen` | `Platen` (flatbed) or `ADF` |

### Examples

```bash
# 300 DPI grayscale letter, saved as PNG
uv run samsung-scanner --host 192.168.1.42 --output scan.png

# 600 DPI grayscale A4, saved as TIFF
uv run samsung-scanner --host 192.168.1.42 --dpi 600 --paper a4 --output scan.tiff

# From ADF, 150 DPI
uv run samsung-scanner --host 192.168.1.42 --dpi 150 --source ADF --output doc.png
```

## Protocol notes

The SL-M2070 exposes its scanner via **WSD (WS-Scan)** — SOAP 1.2 messages sent over plain HTTP to port 8018 (`http://<printer-ip>:8018/wsd/scan`). It does **not** support eSCL (Apple AirScan) and the older Samsung binary SMFP protocol (TCP 9400) is not needed for this model.

The scan sequence is three SOAP calls:

1. **`GetScannerElements`** — checks scanner state and capabilities.
2. **`CreateScanJob`** — sends a `ScanTicket` XML with DPI, color mode, paper size (in 1/1000-inch units), and returns a `JobId` + `JobToken`.
3. **`RetrieveImage`** — streams the scanned image back as a JPEG wrapped in an MTOM (Multipart MIME) HTTP response. Part 0 is a SOAP envelope with an `xop:Include` reference; Part 1 is the raw JPEG binary.

The XML namespace for all scan operations is `http://schemas.microsoft.com/windows/2006/08/wdp/scan` (the "08" date variant, not "01" — real devices implement the former). Image dimensions in the `ScanTicket` are in thousandths of an inch (letter = 8500 × 11000).

To extend this tool (e.g. ADF multi-page, duplex): set `ImagesToTransfer` to `0` in `CreateScanJob` and call `RetrieveImage` in a loop until you get a `ClientErrorNoImagesAvailable` SOAP fault. For duplex, set `InputSource` to `ADFDuplex` and add a `MediaBack` sibling to `MediaFront` in the `ScanTicket`.

Primary sources: [sane-airscan](https://github.com/alexpevzner/sane-airscan) (confirmed working with M2070), [PyWSD](https://github.com/roncapat/WSD-python), [Microsoft WSD Scan spec](https://learn.microsoft.com/en-us/windows-hardware/drivers/image/).
