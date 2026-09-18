# Samsung SULDR / WSD Scan Protocol Research
## Target Device: Samsung SL-M2070 / Xpress M207x Series MFP

*Research date: 2026-09-17. All claims cited to primary sources.*

---

## Table of Contents

1. [Source Code Availability](#1-source-code-availability)
2. [Protocol Selection: WSD vs SMFP](#2-protocol-selection-wsd-vs-smfp)
3. [WSD Network Discovery](#3-wsd-network-discovery)
4. [WSD Scan Protocol — Complete Flow](#4-wsd-scan-protocol--complete-flow)
   - 4.1 Connection
   - 4.2 Capability Query (GetScannerElements)
   - 4.3 Create Scan Job
   - 4.4 Image Retrieval (RetrieveImage)
   - 4.5 Job Cancellation
5. [SMFP Proprietary Binary Protocol (SULDR / xerox_mfp)](#5-smfp-proprietary-binary-protocol-suldr--xerox_mfp)
6. [Cross-Reference: xerox_mfp vs Samsung SL-M2070](#6-cross-reference-xerox_mfp-vs-samsung-sl-m2070)
7. [Existing Python Implementations](#7-existing-python-implementations)
8. [Confirmed vs Inferred](#8-confirmed-vs-inferred)
9. [Gaps Requiring Packet Capture](#9-gaps-requiring-packet-capture)
10. [Recommended Implementation Path](#10-recommended-implementation-path)

---

## 1. Source Code Availability

### SULDR (Samsung Unified Linux Driver Repository)

- **Official site**: https://www.bchemnet.com/suldr/
- **Status**: The drivers are **binary-only — no source code is provided**.
  > "The drivers are binary-only (no source code provided)."
  > — bchemnet.com/suldr/, fetched 2026-09-17
- GitHub mirrors (`jeremy-rutman/suldr`, `catrielmuller/suldr-backup`) contain **only HTML documentation snapshots**, not source code.
- The scanner SANE backend ships as a precompiled shared library at:
  - `/opt/smfp-common/scanner/lib/libsane-smfp.so.1.0.1`
  - `/usr/lib/sane/libsane-smfp.so`
- The network discovery binary ships at:
  - `/opt/smfp-common/printer/bin/smfpnetdiscovery` (proprietary, binary-only)

**Conclusion**: There is no open-source GPL scan driver source from Samsung for the SULDR/SMFP path. The SMFP protocol can only be studied through the open SANE `xerox_mfp` backend (older Samsung devices) or through packet capture.

### Open SANE Backend with Samsung Coverage

- **xerox_mfp** backend in the official SANE project:
  - Source: https://gitlab.com/sane-project/backends/-/raw/master/backend/xerox_mfp.c
  - Header: https://gitlab.com/sane-project/backends/-/raw/master/backend/xerox_mfp.h
  - TCP transport: https://gitlab.com/sane-project/backends/-/raw/master/backend/xerox_mfp-tcp.c
  - Covers Samsung SCX-4500W (network mode), SCX-4521F, SCX-4600, SCX-4729FW and many others
  - Authors: Alex Belkin; network (SCX-4500W) support by Alexander Kuznetsov

- **samsung_mfp** — fork of xerox_mfp optimized for SCX-4600:
  - Source: https://github.com/obermann/samsung_mfp

---

## 2. Protocol Selection: WSD vs SMFP

The Samsung SL-M2070 / M2070W / M2070FW supports **two distinct scan-over-network protocols**:

| Protocol | Port | Status for M2070 | Source |
|----------|------|-------------------|--------|
| **WSD (WS-Scan)** | TCP 8018 | **Confirmed working** | sane-airscan README compatibility table |
| **eSCL (Apple AirScan)** | — | **Not supported** | sane-airscan README: "Samsung M2070 Series — eSCL: No, WSD: Yes" |
| **SMFP proprietary** | TCP 9400 | Uncertain for M2070; works on older SCX models | xerox_mfp source, bchemnet.com forums |

**Confirmed working solution for M2070**:
> "Samsung M2070 Series (SEC30CDA721D058) = http://192.168.178.46:8018/wsd/scan, WSD"
> — Linux Mint Forums, thread "Network scanner Samsung M2070 not detected in Mint 20 but in LMDE 4 [SOLVED]"
> https://forums.linuxmint.com/viewtopic.php?t=341527

The WSD path is the correct approach for the SL-M2070. The remainder of this document focuses on WSD first, then documents SMFP for completeness.

---

## 3. WSD Network Discovery

WSD uses **WS-Discovery** (SOAP over UDP multicast) to find devices on the local network.

### Multicast Parameters (confirmed from sane-airscan source)

| Parameter | Value | Source |
|-----------|-------|--------|
| IPv4 multicast group | `239.255.255.250` | `airscan-wsdd.c`: `inet_pton(AF_INET, "239.255.255.250", ...)` |
| IPv6 multicast group | `ff02::c` | `airscan-wsdd.c`: `inet_pton(AF_INET6, "ff02::c", ...)` |
| UDP port | `3702` | `airscan-wsdd.c`: `htons(3702)` |
| Discovery timeout | 2500 ms (standard), 5000 ms (extended) | `airscan-wsdd.c` constants |

Source: https://github.com/alexpevzner/sane-airscan/blob/master/airscan-wsdd.c

### Probe Message (UDP multicast)

Sent to `239.255.255.250:3702`. The `{{MSG_ID}}` placeholder is replaced with a `urn:uuid:<uuid4>`.

```xml
<?xml version='1.0' encoding='ASCII'?>
<soap:Envelope xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing"
               xmlns:wsd="http://schemas.xmlsoap.org/ws/2005/04/discovery"
               xmlns:soap="http://www.w3.org/2003/05/soap-envelope">
    <soap:Header>
        <wsa:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</wsa:Action>
        <wsa:MessageID>{{MSG_ID}}</wsa:MessageID>
        <wsa:From>
            <wsa:Address>{{FROM}}</wsa:Address>
        </wsa:From>
        <wsa:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</wsa:To>
        <wsa:ReplyTo>{{FROM}}</wsa:ReplyTo>
    </soap:Header>
    <soap:Body>
        <wsd:Probe>
            {{OPT_TYPES}}
        </wsd:Probe>
    </soap:Body>
</soap:Envelope>
```

Source: https://github.com/roncapat/WSD-python/blob/master/src/PyWSD/templates/ws-discovery__probe.xml

### ProbeMatches Response Parsing

The device responds with a `ProbeMatches` SOAP message. The scanner service endpoint is extracted by:

1. Parsing path: `s:Envelope/s:Body/d:ProbeMatches/d:ProbeMatch`
2. Finding `devprof:Hosted` sections where `devprof:Types` contains `"ScannerServiceType"`
3. Extracting `a:EndpointReference/a:Address` — this gives the WSD scan URL

For the M2070, this resolves to: `http://<device-ip>:8018/wsd/scan`

Source: `airscan-wsdd.c` at https://github.com/alexpevzner/sane-airscan/blob/master/airscan-wsdd.c

### Alternative: Manual Configuration

If discovery fails, the WSD endpoint can be specified directly:
```
# In /etc/sane.d/airscan.conf:
[devices]
"My Samsung M2070" = http://192.168.x.x:8018/wsd/scan, WSD
```

---

## 4. WSD Scan Protocol — Complete Flow

All WSD operations are SOAP 1.2 messages sent as HTTP POST to `http://<device-ip>:8018/wsd/scan`.

### HTTP Request Headers (required by sane-airscan / WSDAPI)

```
Content-Type: application/soap+xml
User-Agent: WSDAPI
Cache-Control: no-cache
Pragma: no-cache
```

### XML Namespaces

| Prefix | Namespace URI | Used in |
|--------|--------------|---------|
| `soap` | `http://www.w3.org/2003/05/soap-envelope` | All messages |
| `wsa` | `http://schemas.xmlsoap.org/ws/2004/08/addressing` | All headers |
| `sca` / `wscn` | `http://schemas.microsoft.com/windows/2006/08/wdp/scan` | Scan operations |
| `xop` | `http://www.w3.org/2003/12/xop/include` | Image response |

**Important namespace note**: The correct namespace for scan operations on the M2070 is `http://schemas.microsoft.com/windows/2006/08/wdp/scan` (August 2006, `08`). Microsoft's official documentation examples use the older `windows/2006/01/wdp/scan` (January 2006, `01`), but sane-airscan uses the `08` version which is what actual devices implement.

Source: `airscan-wsd.c` constants; verified at https://github.com/alexpevzner/sane-airscan/blob/master/airscan-wsd.c

### 4.1 Connection

No persistent connection or session setup is required beyond standard TCP. Each SOAP operation is an independent HTTP POST to the endpoint URL. The WSD endpoint URL is discovered once (see §3) and reused for all subsequent operations.

### 4.2 Capability Query (GetScannerElements)

**SOAP Action**: `http://schemas.microsoft.com/windows/2006/08/wdp/scan/GetScannerElements`

**Request body**:

```xml
<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"
               xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing"
               xmlns:sca="http://schemas.microsoft.com/windows/2006/08/wdp/scan">
    <soap:Header>
        <wsa:To>http://192.168.x.x:8018/wsd/scan</wsa:To>
        <wsa:Action>http://schemas.microsoft.com/windows/2006/08/wdp/scan/GetScannerElements</wsa:Action>
        <wsa:MessageID>urn:uuid:{{uuid4}}</wsa:MessageID>
        <wsa:ReplyTo>
            <wsa:Address>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</wsa:Address>
        </wsa:ReplyTo>
        <wsa:From>
            <wsa:Address>urn:uuid:{{client-uuid}}</wsa:Address>
        </wsa:From>
    </soap:Header>
    <soap:Body>
        <sca:GetScannerElementsRequest>
            <sca:RequestedElements>
                <sca:Name>sca:ScannerStatus</sca:Name>
                <sca:Name>sca:ScannerDescription</sca:Name>
                <sca:Name>sca:ScannerConfiguration</sca:Name>
                <sca:Name>sca:DefaultScanTicket</sca:Name>
            </sca:RequestedElements>
        </sca:GetScannerElementsRequest>
    </soap:Body>
</soap:Envelope>
```

Source: https://github.com/roncapat/WSD-python/blob/master/src/PyWSD/templates/ws-scan__get_scanner_elements.xml

**Response parsing** — the device returns a `GetScannerElementsResponse` containing XML paths (using `sca:` prefix, `%s` = source name like `Platen` or `ADF`):

| Capability | XPath |
|------------|-------|
| Resolution widths | `.//sca:%sResolutions/sca:Widths/sca:Width` |
| Resolution heights | `.//sca:%sResolutions/sca:Heights/sca:Height` |
| Optical resolution | `.//sca:%sOpticalResolution/sca:Width` and `Height` |
| Color modes | `.//sca:%sColor/sca:ColorEntry` |
| Min paper size | `.//sca:%sMinimumSize/sca:Width` and `Height` |
| Max paper size | `.//sca:%sMaximumSize/sca:Width` and `Height` |
| Input sources | `.//sca:InputSource` |
| Supported formats | `.//sca:FormatsSupported/sca:FormatValue` |
| Content types | `.//sca:ContentTypesSupported/sca:ContentTypeValue` |
| Scanner state | `.//sca:ScannerState` |

Source: https://github.com/roncapat/WSD-python/blob/master/src/PyWSD/wsd_scan__parsers.py

**Known supported values for M2070 / M207x series** (from WSD schema and sane-airscan devcaps):

| Parameter | Supported values |
|-----------|-----------------|
| `ColorProcessing` | `RGB24`, `Grayscale8`, `BlackAndWhite1` |
| `InputSource` | `Platen` (flatbed), `ADF`, `ADFDuplex` |
| `Format` | `jfif` (JPEG), `tiff-single-g4`, `png`, `pdf-a`, `dib`, `exif` |
| `ContentType` | `Auto`, `Text`, `Photo`, `Halftone`, `Mixed` |
| `ImagesToTransfer` | `1` for flatbed, `0` (unlimited) or `100` for ADF |

Note: The M2070 is a monochrome-only laser printer. Color modes (`RGB24`) may be reported but will produce grayscale output. Confirmed by Apple Community thread: black & white and text scanning work; color produces errors. Source: https://discussions.apple.com/thread/252142616

### 4.3 Create Scan Job

**SOAP Action**: `http://schemas.microsoft.com/windows/2006/08/wdp/scan/CreateScanJob`

**Request template** (from PyWSD, with `wscn` namespace alias for `http://schemas.microsoft.com/windows/2006/01/wdp/scan` — note PyWSD uses `01`, sane-airscan uses `08`; use `08` for the M2070):

```xml
<?xml version="1.0" encoding="ASCII"?>
<soap:Envelope
        xmlns:soap="http://www.w3.org/2003/05/soap-envelope"
        xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing"
        xmlns:wscn="http://schemas.microsoft.com/windows/2006/08/wdp/scan">
    <soap:Header>
        <wsa:To>http://192.168.x.x:8018/wsd/scan</wsa:To>
        <wsa:Action>http://schemas.microsoft.com/windows/2006/08/wdp/scan/CreateScanJob</wsa:Action>
        <wsa:MessageID>urn:uuid:{{uuid4}}</wsa:MessageID>
        <wsa:From>
            <wsa:Address>urn:uuid:{{client-uuid}}</wsa:Address>
        </wsa:From>
        <wsa:ReplyTo>
            <wsa:Address>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</wsa:Address>
        </wsa:ReplyTo>
    </soap:Header>
    <soap:Body>
        <wscn:CreateScanJobRequest>
            <wscn:ScanIdentifier>{{SCAN_ID}}</wscn:ScanIdentifier>
            <wscn:DestinationToken>{{DEST_TOKEN}}</wscn:DestinationToken>
            <wscn:ScanTicket>
                <wscn:JobDescription>
                    <wscn:JobName>{{JOB_NAME}}</wscn:JobName>
                    <wscn:JobOriginatingUserName>{{USER_NAME}}</wscn:JobOriginatingUserName>
                    <wscn:JobInformation>{{JOB_INFO}}</wscn:JobInformation>
                </wscn:JobDescription>
                <wscn:DocumentParameters>
                    <wscn:Format>jfif</wscn:Format>
                    <wscn:CompressionQualityFactor>75</wscn:CompressionQualityFactor>
                    <wscn:ImagesToTransfer>1</wscn:ImagesToTransfer>
                    <wscn:InputSource>Platen</wscn:InputSource>
                    <wscn:ContentType>Auto</wscn:ContentType>
                    <wscn:InputSize>
                        <wscn:DocumentSizeAutoDetect>false</wscn:DocumentSizeAutoDetect>
                        <wscn:InputMediaSize>
                            <wscn:Width>2550</wscn:Width>   <!-- in 1/1000 inch units -->
                            <wscn:Height>3300</wscn:Height>
                        </wscn:InputMediaSize>
                    </wscn:InputSize>
                    <wscn:Exposure>
                        <wscn:AutoExposure>true</wscn:AutoExposure>
                    </wscn:Exposure>
                    <wscn:Scaling>
                        <wscn:ScalingWidth>100</wscn:ScalingWidth>
                        <wscn:ScalingHeight>100</wscn:ScalingHeight>
                    </wscn:Scaling>
                    <wscn:Rotation>0</wscn:Rotation>
                    <wscn:MediaSides>
                        <wscn:MediaFront>
                            <wscn:ScanRegion>
                                <wscn:ScanRegionXOffset>0</wscn:ScanRegionXOffset>
                                <wscn:ScanRegionYOffset>0</wscn:ScanRegionYOffset>
                                <wscn:ScanRegionWidth>2550</wscn:ScanRegionWidth>
                                <wscn:ScanRegionHeight>3300</wscn:ScanRegionHeight>
                            </wscn:ScanRegion>
                            <wscn:ColorProcessing>Grayscale8</wscn:ColorProcessing>
                            <wscn:Resolution>
                                <wscn:Width>300</wscn:Width>
                                <wscn:Height>300</wscn:Height>
                            </wscn:Resolution>
                        </wscn:MediaFront>
                    </wscn:MediaSides>
                </wscn:DocumentParameters>
            </wscn:ScanTicket>
        </wscn:CreateScanJobRequest>
    </soap:Body>
</soap:Envelope>
```

Source: https://github.com/roncapat/WSD-python/blob/master/src/PyWSD/templates/ws-scan__create_scan_job.xml
sane-airscan structure: https://github.com/alexpevzner/sane-airscan/blob/master/airscan-wsd.c

**Parameter notes**:
- `ScanRegion` / `InputMediaSize` dimensions are in **1/1000 inch units** (letter = 8500 x 11000; A4 = 8268 x 11693). This is confirmed by the WSD schema. sane-airscan converts from its internal units; the Microsoft spec confirms units.
- `ScanIdentifier` and `DestinationToken` are only needed for push scanning (button-initiated). For client-initiated scanning, omit them or leave empty.
- `ImagesToTransfer`: `1` for flatbed single page; `0` means unlimited (used with ADF).
- sane-airscan retry behavior: retries `CreateScanJob` up to 30 times with 1000 ms pauses if the device returns temporary-busy responses. Source: `airscan-wsd.c` constants `WSD_CREATE_SCAN_JOB_RETRY_PAUSE = 1000`, `WSD_CREATE_SCAN_JOB_RETRY_ATTEMPTS = 30`.

**Response** — device returns `CreateScanJobResponse` containing:
- `JobId` (integer) at path `s:Envelope/s:Body/scan:CreateScanJobResponse/scan:JobId`
- `JobToken` (string) at path `s:Envelope/s:Body/scan:CreateScanJobResponse/scan:JobToken`

These are stored together as `"<job_id>:<job_token>"` for subsequent requests.

Source: `airscan-wsd.c` (`wsd_scan_decode` function)

### 4.4 Image Retrieval (RetrieveImage)

**SOAP Action**: `http://schemas.microsoft.com/windows/2006/08/wdp/scan/RetrieveImage`

This must be called once per image page. For flatbed with `ImagesToTransfer=1`, call once. For ADF with `ImagesToTransfer=0`, keep calling until the device returns `ClientErrorNoImagesAvailable`.

**Request**:

```xml
<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"
               xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing"
               xmlns:sca="http://schemas.microsoft.com/windows/2006/08/wdp/scan">
    <soap:Header>
        <wsa:To>http://192.168.x.x:8018/wsd/scan</wsa:To>
        <wsa:Action>http://schemas.microsoft.com/windows/2006/08/wdp/scan/RetrieveImage</wsa:Action>
        <wsa:MessageID>urn:uuid:{{uuid4}}</wsa:MessageID>
        <wsa:ReplyTo>
            <wsa:Address>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</wsa:Address>
        </wsa:ReplyTo>
        <wsa:From>
            <wsa:Address>urn:uuid:{{client-uuid}}</wsa:Address>
        </wsa:From>
    </soap:Header>
    <soap:Body>
        <sca:RetrieveImageRequest>
            <sca:JobId>{{JOB_ID}}</sca:JobId>
            <sca:JobToken>{{JOB_TOKEN}}</sca:JobToken>
            <sca:DocumentDescription>
                <sca:DocumentName>IMAGE000.JPG</sca:DocumentName>
            </sca:DocumentDescription>
        </sca:RetrieveImageRequest>
    </soap:Body>
</soap:Envelope>
```

Source: https://github.com/roncapat/WSD-python/blob/master/src/PyWSD/templates/ws-scan__retrieve_image.xml

**Response format** — MTOM (SOAP with Attachments) multipart MIME:

```
mime-version: 1.0
Content-Type: multipart/related;
    type=application/xop+xml;
    boundary=4aa7d814-adc1-47a2-8e1c-07585b9892a4;
    start="<14629f74-2047-436c-8046-5cac76d280fc@uuid>";
    startinfo=application/soap+xml

--4aa7d814-adc1-47a2-8e1c-07585b9892a4
Content-Type: application/xop+xml; type="application/soap+xml"; charset=UTF-8
Content-Transfer-Encoding: binary
Content-ID: <14629f74-2047-436c-8046-5cac76d280fc@uuid>

<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"
               xmlns:xop="http://www.w3.org/2003/12/xop/include"
               xmlns:wscn="http://schemas.microsoft.com/windows/2006/08/wdp/scan">
  <soap:Body>
    <wscn:RetrieveImageResponse>
      <wscn:ScanData>
        <xop:Include href="cid:1c696bd7-005a-48d9-9ee9-9adca11f8892@uuid" />
      </wscn:ScanData>
    </wscn:RetrieveImageResponse>
  </soap:Body>
</soap:Envelope>

--4aa7d814-adc1-47a2-8e1c-07585b9892a4
Content-Type: image/jpeg
Content-Transfer-Encoding: binary
Content-ID: <1c696bd7-005a-48d9-9ee9-9adca11f8892@uuid>

<binary JPEG data>
--4aa7d814-adc1-47a2-8e1c-07585b9892a4--
```

Source: Microsoft WSD documentation — https://learn.microsoft.com/en-us/windows-hardware/drivers/image/retrieveimageresponse

**Parsing**: The JPEG data is in MIME part index 1 (zero-indexed). sane-airscan extracts it via `http_query_get_mp_response_data(ctx->query, 1)`. PyWSD uses Python's `email.message_from_bytes` to parse multipart, then `Image.open(BytesIO(part.get_payload(decode=True)))`.

### 4.5 Job Cancellation

**SOAP Action**: `http://schemas.microsoft.com/windows/2006/08/wdp/scan/CancelJob`

```xml
<soap:Body>
    <sca:CancelJobRequest>
        <sca:JobId>{{JOB_ID}}</sca:JobId>
    </sca:CancelJobRequest>
</soap:Body>
```

Source: sane-airscan `airscan-wsd.c`; PyWSD `ws-scan__cancel_job.xml`

---

## 5. SMFP Proprietary Binary Protocol (SULDR / xerox_mfp)

The SMFP protocol is used by the Samsung proprietary `libsane-smfp.so` backend and the open-source `xerox_mfp` SANE backend (for older Samsung SCX devices). The M2070 likely also implements SMFP on TCP 9400, but WSD is preferred.

### 5.1 Network Transport

| Parameter | Value | Source |
|-----------|-------|--------|
| TCP port | **9400** | `xerox_mfp-tcp.c`: `strport = "9400"` |
| Receive timeout | 1 second | `RECV_TIMEOUT = 1` in `xerox_mfp-tcp.c` |
| Discovery | SNMP UDP (proprietary `smfpnetdiscovery` binary) | bchemnet.com SULDR scanning page |
| Device URI format | `smfp:net;192.168.1.x` | bchemnet.com SULDR forum posts |

Source: https://gitlab.com/sane-project/backends/-/raw/master/backend/xerox_mfp-tcp.c

### 5.2 Protocol Constants

All defined in `xerox_mfp.h`:

```c
// Packet framing magic bytes (every command starts with these two)
REQ_CODE_A = 0x1b
REQ_CODE_B = 0xa8

// Command codes (3rd byte in packet)
CMD_ABORT        = 0x06
CMD_INQUIRY      = 0x12  // capability query
CMD_RESERVE_UNIT = 0x16
CMD_RELEASE_UNIT = 0x17
CMD_SET_WINDOW   = 0x24  // set scan parameters
CMD_READ         = 0x28
CMD_READ_IMAGE   = 0x29  // initiate image transfer

// Response/message codes (byte 3 of response header)
RES_CODE         = 0xa8
MSG_NO_MESSAGE   = 0x00
MSG_PRODUCT_INFO = 0x10  // response to CMD_INQUIRY
MSG_SCANNER_STATE= 0x20
MSG_SCANNING_PARAM = 0x30
MSG_LINK_BLOCK   = 0x80  // intermediate image data block
MSG_END_BLOCK    = 0x81  // final image data block

// Status codes
STATUS_GOOD   = 0x00
STATUS_CHECK  = 0x02
STATUS_CANCEL = 0x04
STATUS_BUSY   = 0x08

// Color/composition modes (used in CMD_SET_WINDOW)
MODE_LINEART  = 0x00
MODE_HALFTONE = 0x01
MODE_GRAY8    = 0x03
MODE_RGB24    = 0x05

// Document source
DOC_ADF      = 0x20
DOC_FLATBED  = 0x40
DOC_AUTO     = 0x80
```

Source: https://gitlab.com/sane-project/backends/-/raw/master/backend/xerox_mfp.h

### 5.3 Packet Structure

Every command packet begins with a 4-byte header:
```
Byte 0: REQ_CODE_A (0x1b)
Byte 1: REQ_CODE_B (0xa8)
Byte 2: command code (CMD_*)
Byte 3: payload length (total packet length = byte[3] + 4)
```

### 5.4 CMD_INQUIRY (Capability Query)

**Request** — 4-byte header only (no payload after header; response expected = 70 bytes):
```c
SANE_Byte cmd[4] = { 0x1b, 0xa8, CMD_INQUIRY /* 0x12 */, 0x00 };
```

**Response parsing** (70-byte response, byte offsets into response buffer `dev->res[]`):

| Offset | Content |
|--------|---------|
| `res[3]` | Must be `MSG_PRODUCT_INFO (0x10)` |
| `res[0x24]`, `res[0x25]`, `res[0x37]` | Resolution bitmap (3 bytes, combined as `res[0x37]<<16 | res[0x24]<<8 | res[0x25]`) |
| `res[0x26]` | ADF status |
| `res[0x27]` | Composition/color modes bitmap |
| `res[0x28..0x2b]` | Max scan width (4 bytes big-endian) |
| `res[0x2c..0x2f]` | Max scan length (4 bytes big-endian) |
| `res[0x32]` | Compression types bitmap: bit 6 (0x40) = JPEG lossy support |
| `res[0x35]` | ADF additional status |

**Resolution bitmap** — each bit in the 3-byte combined value maps to a DPI via array `inq_dpi_bits[]`:
```
Index: 0      1      2      3      4      5    6     7     8     9
DPI:   75    150    200    300    600   1200  100  2400  4800  9600
```

Source: `xerox_mfp.c` at https://gitlab.com/sane-project/backends/-/raw/master/backend/xerox_mfp.c

### 5.5 CMD_SET_WINDOW (25-byte scan parameter packet)

```c
SANE_Byte cmd[0x19] = {
    0x1b, 0xa8,           // REQ_CODE_A, REQ_CODE_B
    CMD_SET_WINDOW,       // 0x24
    0x13,                 // payload length = 0x13, total = 25 bytes
    MSG_SCANNING_PARAM    // 0x30
};
// Scan area dimensions (in internal units, 1/1200 inch):
cmd[0x05] = win_width >> 24;
cmd[0x06] = win_width >> 16;
cmd[0x07] = win_width >> 8;
cmd[0x08] = win_width & 0xff;
cmd[0x09] = win_len >> 24;
cmd[0x0a] = win_len >> 16;
cmd[0x0b] = win_len >> 8;
cmd[0x0c] = win_len & 0xff;
// Resolution (same x and y DPI code):
cmd[0x0d] = resolution_code;
cmd[0x0e] = resolution_code;
// Scan offset (integer part, then fractional x 100):
cmd[0x0f] = floor(win_off_x);
cmd[0x10] = (win_off_x - floor(win_off_x)) * 100;
cmd[0x11] = floor(win_off_y);
cmd[0x12] = (win_off_y - floor(win_off_y)) * 100;
// Composition mode:
cmd[0x13] = composition;  // MODE_LINEART/GRAY8/RGB24
// JPEG compression: 0x06 = enable JPEG
cmd[0x14] = 0x6;
// Threshold (for lineart):
cmd[0x16] = threshold;
// Document source:
cmd[0x17] = doc_source;   // DOC_FLATBED=0x40, DOC_ADF=0x20
```

Source: `xerox_mfp.c`

### 5.6 CMD_READ_IMAGE and Image Block Transfer

**Request** — minimal 4-byte header:
```c
{ 0x1b, 0xa8, 0x29 /* CMD_READ_IMAGE */, 0x00 }
```

The device then streams image data in blocks. Each block has a header:

| Offset | Content |
|--------|---------|
| `res[3]` | `MSG_LINK_BLOCK (0x80)` for intermediate, `MSG_END_BLOCK (0x81)` for final |
| `res[4..7]` | Block payload length (4 bytes big-endian) |
| `res[0x08..0x09]` | Vertical dimension (lines) |
| `res[0x0a..0x0b]` | Horizontal dimension (pixels) |

Interpretation: if `res[3] == MSG_END_BLOCK`, this is the last block; stop reading. Each block is followed by `blocklen` bytes of image data (raw scanlines or JPEG chunks depending on `cmd[0x14]` JPEG flag).

Source: `xerox_mfp.c`

### 5.7 SMFP Network Discovery

The Samsung proprietary `smfpnetdiscovery` binary uses SNMP to locate scanners:
- Command: `/opt/Samsung/mfp/bin/netdiscovery --all --scanner`
- SNMP requires UDP port 161 open on the device
- SNMP must be enabled on the printer (printer admin web UI)

The discovery output produces addresses in `smfp:net;x.x.x.x` format.

Source: https://www.bchemnet.com/suldr/scanning.html

---

## 6. Cross-Reference: xerox_mfp vs Samsung SL-M2070

| Feature | xerox_mfp (SCX-4500W etc.) | Samsung SL-M2070 |
|---------|---------------------------|-----------------|
| Protocol | SMFP binary over TCP 9400 | **WSD (WS-Scan) over TCP 8018** |
| Discovery | SNMP UDP broadcast (proprietary binary) | WS-Discovery UDP multicast 239.255.255.250:3702 |
| Capability query | `CMD_INQUIRY` binary packet | SOAP `GetScannerElements` |
| Scan setup | `CMD_SET_WINDOW` 25-byte binary packet | SOAP `CreateScanJob` with XML `ScanTicket` |
| Image transfer | Binary blocks with `MSG_LINK_BLOCK`/`MSG_END_BLOCK` framing | MTOM multipart MIME with JPEG attachment |
| Image format | Raw scanlines or JPEG (selected by `cmd[0x14]`) | JPEG/JFIF (via `Format` element) |
| Session teardown | `CMD_RELEASE_UNIT` | `CancelJob` SOAP if needed; otherwise no teardown |
| eSCL support | No | No |
| Open source driver | Yes (xerox_mfp in SANE) | No (SMFP binary-only); WSD path is open |

**Conclusion**: The SL-M2070 uses a fundamentally different protocol stack from the older SCX models. The xerox_mfp binary protocol is **not applicable** to the M2070 over the network. The M2070's correct network scan protocol is WSD/WS-Scan.

---

## 7. Existing Python Implementations

### 7.1 sane-airscan (C, confirmed working with M2070)

- **Repo**: https://github.com/alexpevzner/sane-airscan
- **Language**: C
- **Status**: Confirmed working — M2070 listed in compatibility table as WSD:Yes
- **Key files**: `airscan-wsd.c`, `airscan-wsdd.c`
- **Install**: Available in most Linux package managers

### 7.2 WSD-python / PyWSD (Python)

- **Repo**: https://github.com/roncapat/WSD-python
- **Language**: Python 3.6+
- **Status**: Library (~70% complete per author), implements the full WS-Scan operation set
- **Dependencies**: `lxml`, `requests`, `Pillow`
- **Key modules**:
  - `wsd_scan__operations.py` — `wsd_get_scanner_elements()`, `wsd_create_scan_job()`, `wsd_retrieve_image()`, `wsd_cancel_job()`
  - `wsd_discovery__operations.py` — multicast Probe, ProbeMatches parsing
  - `templates/` — all SOAP XML templates
- **Note**: Uses `wscn` namespace with `windows/2006/01/wdp/scan`; may need updating to `08` for M2070 compatibility

### 7.3 wsd-scan (Python, push-scan focused)

- **Repo**: https://github.com/Tobag/wsd-scan
- **Language**: Python 3.6+
- **Status**: Working; tested with Samsung M288x Series
- **Purpose**: Implements device-initiated (push) scanning via `ScanAvailableEvent` subscription
- **Dependencies**: `lxml`, `requests`, `Pillow`, `yaml`
- **Note**: Designed around printer-button-initiated scans, not PC-initiated pull scans. May be adaptable.

### 7.4 pyWSDscan

- **Repo**: https://yingtongli.me/git/pyWSDscan/ (moved from GitHub)
- **Language**: Python
- **Status**: Unknown (project moved, original GitHub repo shows redirect only)

### 7.5 WSDolefuls/WSD.py

- **Repo**: https://github.com/al42and/WSDolefuls
- **Language**: Python
- **Note**: Single-file implementation; uses port 80 with `/wsd/scanservice.cgi` path (device-specific, not M2070 format). Uses XML templates stored externally.

---

## 8. Confirmed vs Inferred

### Confirmed (from primary source code / live reports)

- M2070 WSD endpoint: `http://<ip>:8018/wsd/scan` — confirmed from Linux Mint forum with actual device output
- M2070 is WSD-only (no eSCL) — sane-airscan compatibility table, primary source
- WS-Discovery multicast: `239.255.255.250:3702` UDP — sane-airscan and PyWSD source code
- SOAP action URIs — sane-airscan `airscan-wsd.c` constants
- MTOM multipart response format for RetrieveImage — Microsoft WSD spec (primary)
- JobId/JobToken extraction XPaths — sane-airscan source
- GetScannerElements XML template — PyWSD templates directory
- CreateScanJob XML template — PyWSD templates directory
- RetrieveImage XML template — PyWSD templates directory
- xerox_mfp TCP port 9400 — `xerox_mfp-tcp.c` source code
- xerox_mfp binary protocol constants — `xerox_mfp.h` source code
- xerox_mfp CMD_SET_WINDOW packet structure — `xerox_mfp.c` source code
- SMFP binary-only (no source) — bchemnet.com SULDR page explicit statement

### Inferred (from related sources, not M2070-specific)

- Scan area dimensions in WSD are in 1/1000 inch units — inferred from WSD schema and sane-airscan parameter handling; not explicitly confirmed for M2070
- M2070 SMFP on TCP 9400 — older Samsung devices use this; M2070 may too but WSD confirmed working first
- `Format=jfif` is the primary usable format — inferred from sane-airscan default and device behavior; device may support others
- M2070 cannot produce true color scans (monochrome printer) — inferred from Apple Community thread showing color scan failures; WSD may report `RGB24` capability but produce grayscale
- `Grayscale8` and `BlackAndWhite1` are the reliable color modes for M2070

---

## 9. Gaps Requiring Packet Capture

The following questions **cannot be answered from available source code** and require a Wireshark/tcpdump capture between a working client (Linux with sane-airscan, or Windows) and the M2070:

1. **Exact GetScannerElementsResponse XML** from the M2070: which resolutions, which color modes, which formats does the device actually report? The schema says `RGB24` is a valid enum but M2070 may only advertise `Grayscale8` and `BlackAndWhite1`.

2. **MIME boundary string format**: The boundary in the MTOM response is device-generated. Understanding the exact Content-Type header format the M2070 emits is needed to write a robust parser.

3. **HTTP behavior**: Does the M2070 use `Transfer-Encoding: chunked` for the image data, or does it send `Content-Length`? Does it keep the TCP connection alive between calls?

4. **ScanRegion unit system**: Confirm whether the M2070 uses 1/1000 inch, 1/1200 inch, or some other unit for width/height in the CreateScanJob. sane-airscan uses 1/1000 of a mm (300 DPI equivalent) internally and converts.

5. **WSD namespace version**: Confirm empirically whether the M2070 accepts requests using `windows/2006/08/wdp/scan` vs `windows/2006/01/wdp/scan`. The sane-airscan `08` version is strongly inferred but not confirmed with a packet capture.

6. **SMFP reachability on M2070**: Does the M2070 also listen on TCP 9400 for the SMFP binary protocol? If so, does it respond to `CMD_INQUIRY` (0x1b 0xa8 0x12 0x00)?

7. **Image format in practice**: Does `Format=jfif` return standard JPEG? Or does it return a different encoding?

---

## 10. Recommended Implementation Path

For a Python CLI tool that scans the M2070 over the network, the recommended approach is:

### Step 1: Direct WSD via HTTP (no SANE dependency)

Use Python's `requests` library to send SOAP over HTTP directly to the WSD endpoint. This completely bypasses macOS ICA/SANE.

```python
import requests
import uuid
from email import message_from_bytes

SCANNER_URL = "http://192.168.x.x:8018/wsd/scan"
CLIENT_URN = f"urn:uuid:{uuid.uuid4()}"

HEADERS = {
    "Content-Type": "application/soap+xml",
    "User-Agent": "WSDAPI",
    "Cache-Control": "no-cache",
}

def make_msg_id():
    return f"urn:uuid:{uuid.uuid4()}"

def get_scanner_elements():
    # Use the GetScannerElements template from §4.2
    # Parse response with lxml to extract capabilities
    ...

def create_scan_job(dpi=300, color="Grayscale8", source="Platen", fmt="jfif"):
    # Use the CreateScanJob template from §4.3
    # Returns (job_id, job_token)
    ...

def retrieve_image(job_id, job_token):
    # Use the RetrieveImage template from §4.4
    # Parse MTOM multipart response, return JPEG bytes
    ...
```

### Step 2: Namespace to try first

Use `http://schemas.microsoft.com/windows/2006/08/wdp/scan` (as sane-airscan does). If the device rejects with 400, try `http://schemas.microsoft.com/windows/2006/01/wdp/scan`.

### Step 3: Reference implementations

- Start with PyWSD's XML templates (confirmed parseable): https://github.com/roncapat/WSD-python/tree/master/src/PyWSD/templates
- Study sane-airscan's retry logic and WSD flow: https://github.com/alexpevzner/sane-airscan/blob/master/airscan-wsd.c
- For MTOM parsing in Python: use `email.message_from_bytes()` on the raw HTTP response body (after stripping HTTP headers)

---

## Sources Index

| URL | What it provided |
|-----|-----------------|
| https://www.bchemnet.com/suldr/ | SULDR driver info, binary-only confirmation |
| https://www.bchemnet.com/suldr/scanning.html | SMFP network config, smfpnetdiscovery, `smfp:net` URI format |
| https://www.bchemnet.com/suldr/forum/index.php?topic=257.0 | M2070 network scan troubleshooting, `smfp:net;192.168.1.50` URI |
| https://github.com/alexpevzner/sane-airscan | Primary WSD implementation; M2070 compatibility table |
| https://github.com/alexpevzner/sane-airscan/blob/master/airscan-wsd.c | WSD SOAP actions, XML structure, JobId parsing, retry constants |
| https://github.com/alexpevzner/sane-airscan/blob/master/airscan-wsdd.c | WS-Discovery multicast address, port 3702, Probe XML |
| https://github.com/roncapat/WSD-python | PyWSD Python library |
| https://github.com/roncapat/WSD-python/blob/master/src/PyWSD/wsd_scan__operations.py | Function signatures, template names, operation flow |
| https://github.com/roncapat/WSD-python/blob/master/src/PyWSD/wsd_scan__parsers.py | XPath strings for capability parsing |
| https://github.com/roncapat/WSD-python/blob/master/src/PyWSD/wsd_common.py | HTTP POST structure, headers, template substitution |
| https://raw.githubusercontent.com/roncapat/WSD-python/master/src/PyWSD/templates/ws-scan__get_scanner_elements.xml | Verbatim SOAP XML |
| https://raw.githubusercontent.com/roncapat/WSD-python/master/src/PyWSD/templates/ws-scan__create_scan_job.xml | Verbatim SOAP XML |
| https://raw.githubusercontent.com/roncapat/WSD-python/master/src/PyWSD/templates/ws-scan__retrieve_image.xml | Verbatim SOAP XML |
| https://raw.githubusercontent.com/roncapat/WSD-python/master/src/PyWSD/templates/ws-discovery__probe.xml | WS-Discovery Probe XML |
| https://github.com/Tobag/wsd-scan | Python push-scan implementation |
| https://gitlab.com/sane-project/backends/-/raw/master/backend/xerox_mfp.h | SMFP protocol constants (REQ_CODE_A/B, CMD_*, MSG_*) |
| https://gitlab.com/sane-project/backends/-/raw/master/backend/xerox_mfp.c | SMFP packet structures, CMD_SET_WINDOW, image block parsing |
| https://gitlab.com/sane-project/backends/-/raw/master/backend/xerox_mfp-tcp.c | TCP port 9400 |
| https://github.com/obermann/samsung_mfp | Samsung SCX-4600 SANE backend |
| https://forums.linuxmint.com/viewtopic.php?t=341527 | **M2070 confirmed WSD working** at `http://<ip>:8018/wsd/scan` |
| https://github.com/alexpevzner/sane-airscan/issues/170 | Samsung M2875FD WSD debugging, port 8018, 400 Bad Request |
| https://learn.microsoft.com/en-us/windows-hardware/drivers/image/createscanjobrequest | Microsoft WSD Scan spec, example XML |
| https://learn.microsoft.com/en-us/windows-hardware/drivers/image/retrieveimageresponse | MTOM multipart response format, verbatim example |
| https://learn.microsoft.com/en-us/windows-hardware/drivers/image/wsd-scan-service-operation-elements | Full list of WSD scan operations |
| https://discussions.apple.com/thread/252142616 | M2070W color scan failure, monochrome-only confirmed |
| https://bugzilla.redhat.com/show_bug.cgi?id=1530216 | SMFP vs WSD, `smfp:net` vs `xerox_mfp:tcp` URI formats |
