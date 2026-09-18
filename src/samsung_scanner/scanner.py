#!/usr/bin/env python3
"""
Samsung SL-M2070 network scanner client.

Protocol: WSD (WS-Scan) — SOAP 1.2 over HTTP POST to port 8018.
Image transfer: MTOM multipart response; image is JPEG in part 1.
No platform scan framework (ICA/TWAIN/SANE) is used.

References (all primary sources):
  sane-airscan airscan-wsd.c  – https://github.com/alexpevzner/sane-airscan
  PyWSD templates             – https://github.com/roncapat/WSD-python
  MS WSD Scan spec            – https://learn.microsoft.com/en-us/windows-hardware/drivers/image/
"""

import argparse
import io
import re
import sys
import time
import uuid
import xml.etree.ElementTree as ET
from http.client import HTTPConnection
from pathlib import Path

# ── WSD endpoint ────────────────────────────────────────────────────────────

WSD_PORT = 8018
WSD_PATH = "/wsd/scan"

# ── XML namespaces ───────────────────────────────────────────────────────────
# The scan namespace uses the "08" (August 2006) date — sane-airscan confirmed
# this is what actual devices implement; the MS docs show "01" but that breaks.
NS_SOAP = "http://www.w3.org/2003/05/soap-envelope"
NS_WSA  = "http://schemas.xmlsoap.org/ws/2004/08/addressing"
NS_SCAN = "http://schemas.microsoft.com/windows/2006/08/wdp/scan"
NS_SCAN_ALT = "http://schemas.microsoft.com/windows/2006/01/wdp/scan"  # fallback

WSA_ANON = "http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous"

# ── HTTP headers (required by WSDAPI / device expectation) ──────────────────

_BASE_HEADERS = {
    "Content-Type": "application/soap+xml",
    "User-Agent":   "WSDAPI",
    "Cache-Control": "no-cache",
    "Pragma":        "no-cache",
}

# ── Retry settings (mirrors sane-airscan defaults) ───────────────────────────

CREATE_JOB_MAX_ATTEMPTS = 30
CREATE_JOB_RETRY_PAUSE  = 1.0   # seconds between retries

# ── Paper sizes in 1/1000-inch units (letter=8.5×11 in, A4=8.268×11.693 in) ─

PAPER_SIZES: dict[str, tuple[int, int]] = {
    "letter": (8500, 11000),
    "a4":     (8268, 11693),
    "legal":  (8500, 14000),
}

COLOR_MODES: dict[str, str] = {
    "grayscale": "Grayscale8",
    "color":     "RGB24",          # M2070 is monochrome; will still produce gray
    "bw":        "BlackAndWhite1",
}

# ── Session-scoped client UUID ────────────────────────────────────────────────

_CLIENT_URN = f"urn:uuid:{uuid.uuid4()}"


# ════════════════════════════════════════════════════════════════════════════
# Error type
# ════════════════════════════════════════════════════════════════════════════

class ScannerError(Exception):
    """User-facing scanner error (printed without a traceback)."""


# ════════════════════════════════════════════════════════════════════════════
# SOAP XML builders
# ════════════════════════════════════════════════════════════════════════════

def _msg_id() -> str:
    return f"urn:uuid:{uuid.uuid4()}"


def _envelope(to_url: str, action: str, body_xml: str,
              ns: str = NS_SCAN) -> str:
    return (
        f'<?xml version="1.0" encoding="utf-8"?>\n'
        f'<soap:Envelope xmlns:soap="{NS_SOAP}"'
        f' xmlns:wsa="{NS_WSA}"'
        f' xmlns:sca="{ns}">\n'
        f'  <soap:Header>\n'
        f'    <wsa:To>{to_url}</wsa:To>\n'
        f'    <wsa:Action>{action}</wsa:Action>\n'
        f'    <wsa:MessageID>{_msg_id()}</wsa:MessageID>\n'
        f'    <wsa:ReplyTo><wsa:Address>{WSA_ANON}</wsa:Address></wsa:ReplyTo>\n'
        f'    <wsa:From><wsa:Address>{_CLIENT_URN}</wsa:Address></wsa:From>\n'
        f'  </soap:Header>\n'
        f'  <soap:Body>\n{body_xml}\n  </soap:Body>\n'
        f'</soap:Envelope>'
    )


def _get_elements_body() -> str:
    return """\
    <sca:GetScannerElementsRequest>
      <sca:RequestedElements>
        <sca:Name>sca:ScannerStatus</sca:Name>
        <sca:Name>sca:ScannerDescription</sca:Name>
        <sca:Name>sca:ScannerConfiguration</sca:Name>
        <sca:Name>sca:DefaultScanTicket</sca:Name>
      </sca:RequestedElements>
    </sca:GetScannerElementsRequest>"""


def _create_job_body(dpi: int, color_mode: str,
                     source: str, paper: tuple[int, int]) -> str:
    w, h = paper
    return (
        f"    <sca:CreateScanJobRequest>\n"
        f"      <sca:ScanTicket>\n"
        f"        <sca:JobDescription>\n"
        f"          <sca:JobName>SamsungScan</sca:JobName>\n"
        f"          <sca:JobOriginatingUserName>user</sca:JobOriginatingUserName>\n"
        f"        </sca:JobDescription>\n"
        f"        <sca:DocumentParameters>\n"
        f"          <sca:Format>jfif</sca:Format>\n"
        f"          <sca:CompressionQualityFactor>85</sca:CompressionQualityFactor>\n"
        f"          <sca:ImagesToTransfer>1</sca:ImagesToTransfer>\n"
        f"          <sca:InputSource>{source}</sca:InputSource>\n"
        f"          <sca:ContentType>Auto</sca:ContentType>\n"
        f"          <sca:InputSize>\n"
        f"            <sca:DocumentSizeAutoDetect>false</sca:DocumentSizeAutoDetect>\n"
        f"            <sca:InputMediaSize>\n"
        f"              <sca:Width>{w}</sca:Width>\n"
        f"              <sca:Height>{h}</sca:Height>\n"
        f"            </sca:InputMediaSize>\n"
        f"          </sca:InputSize>\n"
        f"          <sca:Exposure><sca:AutoExposure>true</sca:AutoExposure></sca:Exposure>\n"
        f"          <sca:Scaling>\n"
        f"            <sca:ScalingWidth>100</sca:ScalingWidth>\n"
        f"            <sca:ScalingHeight>100</sca:ScalingHeight>\n"
        f"          </sca:Scaling>\n"
        f"          <sca:MediaSides>\n"
        f"            <sca:MediaFront>\n"
        f"              <sca:ScanRegion>\n"
        f"                <sca:ScanRegionXOffset>0</sca:ScanRegionXOffset>\n"
        f"                <sca:ScanRegionYOffset>0</sca:ScanRegionYOffset>\n"
        f"                <sca:ScanRegionWidth>{w}</sca:ScanRegionWidth>\n"
        f"                <sca:ScanRegionHeight>{h}</sca:ScanRegionHeight>\n"
        f"              </sca:ScanRegion>\n"
        f"              <sca:ColorProcessing>{color_mode}</sca:ColorProcessing>\n"
        f"              <sca:Resolution>\n"
        f"                <sca:Width>{dpi}</sca:Width>\n"
        f"                <sca:Height>{dpi}</sca:Height>\n"
        f"              </sca:Resolution>\n"
        f"            </sca:MediaFront>\n"
        f"          </sca:MediaSides>\n"
        f"        </sca:DocumentParameters>\n"
        f"      </sca:ScanTicket>\n"
        f"    </sca:CreateScanJobRequest>"
    )


def _retrieve_image_body(job_id: str, job_token: str) -> str:
    return (
        f"    <sca:RetrieveImageRequest>\n"
        f"      <sca:JobId>{job_id}</sca:JobId>\n"
        f"      <sca:JobToken>{job_token}</sca:JobToken>\n"
        f"      <sca:DocumentDescription>\n"
        f"        <sca:DocumentName>IMAGE000.JPG</sca:DocumentName>\n"
        f"      </sca:DocumentDescription>\n"
        f"    </sca:RetrieveImageRequest>"
    )


def _cancel_job_body(job_id: str) -> str:
    return (
        f"    <sca:CancelJobRequest>\n"
        f"      <sca:JobId>{job_id}</sca:JobId>\n"
        f"    </sca:CancelJobRequest>"
    )


# ════════════════════════════════════════════════════════════════════════════
# HTTP transport
# ════════════════════════════════════════════════════════════════════════════

def _soap_post(host: str, soap_body: str, action: str,
               timeout: int = 30) -> tuple[dict[str, str], bytes]:
    """POST a SOAP envelope; return (lowercased-headers, raw-response-body)."""
    encoded = soap_body.encode("utf-8")
    headers = dict(_BASE_HEADERS)
    headers["Content-Length"] = str(len(encoded))
    headers["SOAPAction"] = f'"{action}"'

    try:
        conn = HTTPConnection(host, WSD_PORT, timeout=timeout)
        conn.request("POST", WSD_PATH, body=encoded, headers=headers)
        resp = conn.getresponse()
        raw = resp.read()
        conn.close()
    except OSError as exc:
        raise ScannerError(
            f"Cannot reach {host}:{WSD_PORT} — is the printer on and reachable?\n"
            f"  Detail: {exc}"
        ) from exc

    resp_headers = {k.lower(): v for k, v in resp.getheaders()}

    if resp.status == 400:
        raise ScannerError(
            f"HTTP 400 from printer — possible namespace mismatch "
            f"(tried {NS_SCAN}). Raw: {raw[:300].decode(errors='replace')}"
        )
    if resp.status not in (200, 202):
        _raise_soap_fault(resp.status, raw)

    return resp_headers, raw


def _raise_soap_fault(status: int, raw: bytes) -> None:
    try:
        root = ET.fromstring(raw)
        # Look for a SOAP Fault text
        for tag in (f"{{{NS_SOAP}}}Text", "Text"):
            el = root.find(f".//{tag}")
            if el is not None and el.text:
                raise ScannerError(f"HTTP {status} / SOAP fault: {el.text.strip()}")
    except (ET.ParseError, ScannerError):
        pass
    raise ScannerError(
        f"HTTP {status} from printer. Body: {raw[:300].decode(errors='replace')}"
    )


# ════════════════════════════════════════════════════════════════════════════
# MTOM (multipart MIME) parser — manual boundary split for binary safety
# ════════════════════════════════════════════════════════════════════════════

def _extract_jpeg_from_mtom(resp_headers: dict[str, str], raw_body: bytes) -> bytes:
    """
    Split an MTOM response on the MIME boundary and return the binary payload
    of part index 1 (the JPEG image), stripping part headers.
    """
    content_type = resp_headers.get("content-type", "")

    # If response is not multipart (e.g. device returns raw image) just pass through
    if "multipart" not in content_type.lower():
        return raw_body

    m = re.search(r'boundary=(?:"([^"]+)"|([^\s;]+))', content_type, re.IGNORECASE)
    if not m:
        raise ScannerError(
            "MTOM Content-Type has no boundary parameter — cannot parse image"
        )
    boundary = (m.group(1) or m.group(2)).encode()

    # Split on --boundary; each segment after the first delimiter is a part
    delimiter = b"--" + boundary
    segments = raw_body.split(delimiter)
    # segments[0]: preamble (empty or whitespace)
    # segments[1..N-1]: MIME parts
    # segments[-1]: epilogue (--\r\n)

    parts: list[bytes] = []
    for seg in segments[1:]:
        if seg.startswith(b"--"):   # closing delimiter --boundary--
            break
        seg = seg.lstrip(b"\r\n")
        # Split part headers from body at first blank line
        for sep in (b"\r\n\r\n", b"\n\n"):
            if sep in seg:
                _, body = seg.split(sep, 1)
                parts.append(body.rstrip(b"\r\n"))
                break

    if len(parts) < 2:
        raise ScannerError(
            f"Expected ≥2 MIME parts in MTOM response, got {len(parts)}. "
            "The scanner may not have found a document to scan."
        )
    return parts[1]


# ════════════════════════════════════════════════════════════════════════════
# XML helpers
# ════════════════════════════════════════════════════════════════════════════

def _find(root: ET.Element, local: str, ns: str = NS_SCAN) -> ET.Element | None:
    return root.find(f".//{{{ns}}}{local}")


def _text(root: ET.Element, local: str, ns: str = NS_SCAN) -> str | None:
    el = _find(root, local, ns)
    return el.text if el is not None else None


# ════════════════════════════════════════════════════════════════════════════
# Scanner client
# ════════════════════════════════════════════════════════════════════════════

class SamsungWSDScanner:
    def __init__(self, host: str):
        self.host = host
        self.url  = f"http://{host}:{WSD_PORT}{WSD_PATH}"

    # ── GetScannerElements ──────────────────────────────────────────────────

    def get_scanner_elements(self) -> dict:
        action = f"{NS_SCAN}/GetScannerElements"
        soap   = _envelope(self.url, action, _get_elements_body())
        _, raw = _soap_post(self.host, soap, action)

        try:
            root = ET.fromstring(raw)
        except ET.ParseError as exc:
            raise ScannerError(f"Invalid XML from GetScannerElements: {exc}")

        state = _text(root, "ScannerState") or "Unknown"
        return {"state": state}

    # ── CreateScanJob ───────────────────────────────────────────────────────

    def create_scan_job(self, dpi: int, color_mode: str,
                        source: str, paper: tuple[int, int]) -> tuple[str, str]:
        action = f"{NS_SCAN}/CreateScanJob"
        soap   = _envelope(self.url, action,
                           _create_job_body(dpi, color_mode, source, paper))

        for attempt in range(CREATE_JOB_MAX_ATTEMPTS):
            try:
                _, raw = _soap_post(self.host, soap, action)
            except ScannerError as exc:
                msg = str(exc)
                if "503" in msg or "busy" in msg.lower():
                    print(f"  Printer busy — retry {attempt+1}/{CREATE_JOB_MAX_ATTEMPTS} …")
                    time.sleep(CREATE_JOB_RETRY_PAUSE)
                    continue
                raise

            try:
                root = ET.fromstring(raw)
            except ET.ParseError as exc:
                raise ScannerError(f"Invalid XML from CreateScanJob: {exc}")

            job_id    = _text(root, "JobId")
            job_token = _text(root, "JobToken") or ""

            if not job_id:
                raise ScannerError(
                    "Printer returned no JobId — "
                    "is there a document on the glass/ADF?"
                )
            return job_id, job_token

        raise ScannerError("CreateScanJob failed after all retries")

    # ── RetrieveImage ───────────────────────────────────────────────────────

    def retrieve_image(self, job_id: str, job_token: str) -> bytes:
        action = f"{NS_SCAN}/RetrieveImage"
        soap   = _envelope(self.url, action,
                           _retrieve_image_body(job_id, job_token))
        resp_headers, raw = _soap_post(self.host, soap, action, timeout=90)
        return _extract_jpeg_from_mtom(resp_headers, raw)

    # ── CancelJob ───────────────────────────────────────────────────────────

    def cancel_job(self, job_id: str) -> None:
        try:
            action = f"{NS_SCAN}/CancelJob"
            soap   = _envelope(self.url, action, _cancel_job_body(job_id))
            _soap_post(self.host, soap, action)
        except ScannerError:
            pass  # best-effort

    # ── High-level scan ─────────────────────────────────────────────────────

    def scan(self, dpi: int, color_mode: str,
             paper_name: str = "letter", source: str = "Platen") -> bytes:
        paper = PAPER_SIZES.get(paper_name, PAPER_SIZES["letter"])

        print(f"Querying scanner at {self.url} …")
        caps  = self.get_scanner_elements()
        state = caps["state"]
        if state.lower() not in ("idle", "processing", "testing"):
            print(f"Warning: scanner state is '{state}' — proceeding anyway.")
        else:
            print(f"Scanner ready (state: {state}).")

        mode_label = {v: k for k, v in COLOR_MODES.items()}.get(color_mode, color_mode)
        print(f"Creating scan job: {dpi} DPI · {mode_label} · {paper_name} · {source} …")
        job_id, job_token = self.create_scan_job(dpi, color_mode, source, paper)
        print(f"Job accepted (id={job_id}).")

        print("Scanning — please wait …")
        try:
            jpeg = self.retrieve_image(job_id, job_token)
        except ScannerError:
            self.cancel_job(job_id)
            raise

        print(f"Received {len(jpeg):,} bytes.")
        return jpeg


# ════════════════════════════════════════════════════════════════════════════
# Image output
# ════════════════════════════════════════════════════════════════════════════

def save_image(jpeg_bytes: bytes, dpi: int, output_path: Path) -> None:
    try:
        from PIL import Image
    except ImportError:
        sys.exit("Pillow is required:  pip install Pillow")

    img    = Image.open(io.BytesIO(jpeg_bytes))
    suffix = output_path.suffix.lower()
    if suffix in (".tif", ".tiff"):
        img.save(output_path, format="TIFF", dpi=(dpi, dpi))
    else:
        img.save(output_path, format="PNG",  dpi=(dpi, dpi))

    print(f"Saved: {output_path}  ({img.width}×{img.height} px at {dpi} DPI)")


# ════════════════════════════════════════════════════════════════════════════
# CLI
# ════════════════════════════════════════════════════════════════════════════

def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description=(
            "Scan from a Samsung SL-M2070 series network MFP using the WSD "
            "(WS-Scan / SOAP) protocol.  No platform driver required."
        ),
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    p.add_argument("--host", required=True, metavar="IP",
                   help="Printer IP address")
    p.add_argument("--dpi", type=int, default=300,
                   choices=[75, 150, 200, 300, 600],
                   help="Scan resolution (DPI)")

    grp = p.add_mutually_exclusive_group()
    grp.add_argument("--grayscale", dest="color_key",
                     action="store_const", const="grayscale",
                     help="Grayscale scan (default; recommended for M2070)")
    grp.add_argument("--color", dest="color_key",
                     action="store_const", const="color",
                     help="RGB color mode (M2070 is monochrome — output will be gray)")
    grp.add_argument("--bw", dest="color_key",
                     action="store_const", const="bw",
                     help="Black & white (1-bit)")
    p.set_defaults(color_key="grayscale")

    p.add_argument("--paper", default="letter",
                   choices=list(PAPER_SIZES),
                   help="Paper size")
    p.add_argument("--source", default="Platen",
                   choices=["Platen", "ADF"],
                   help="Document source")
    p.add_argument("--output", "-o", required=True, metavar="FILE",
                   help="Output file path (.png or .tiff)")
    return p


def main() -> None:
    args   = _build_parser().parse_args()
    output = Path(args.output)

    if output.suffix.lower() not in (".png", ".tif", ".tiff"):
        sys.exit("Output must end in .png, .tif, or .tiff")

    try:
        scanner    = SamsungWSDScanner(args.host)
        jpeg_bytes = scanner.scan(
            dpi        = args.dpi,
            color_mode = COLOR_MODES[args.color_key],
            paper_name = args.paper,
            source     = args.source,
        )
        save_image(jpeg_bytes, args.dpi, output)
    except ScannerError as exc:
        sys.exit(f"Error: {exc}")
    except KeyboardInterrupt:
        sys.exit("\nInterrupted.")


if __name__ == "__main__":
    main()
