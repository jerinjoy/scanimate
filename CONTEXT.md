# Scanimate

A macOS app that scans from a Samsung SL-M2070 series network MFP using the WSD protocol, replacing Apple's Image Capture for devices it no longer detects.

## Language

**Scanner**:
The physical Samsung SL-M2070 network printer/scanner, accessed by IP address over the local network.
_Avoid_: Printer, device, MFP

**WSD (WS-Scan)**:
The wire protocol used to communicate with the Scanner — SOAP 1.2 over HTTP on port 8018. The August-2006 namespace variant (`08`) must be used; the January-2006 (`01`) variant causes HTTP 400 on real devices.
_Avoid_: TWAIN, ICA, WIA (those are OS-level scan frameworks; this app bypasses them entirely)

**ScanTicket**:
The bundle of parameters that describe a desired scan: resolution (DPI), color mode, paper size, and input source. Submitted once when a ScanJob is created.
_Avoid_: Scan settings, scan parameters, scan options

**ScanJob**:
A single scan operation, from the moment a ScanTicket is submitted to the Scanner until all pages are retrieved or the job fails or is cancelled. The Scanner assigns a JobId and JobToken when the job is accepted.
_Avoid_: Scan session, scan request

**ScanResult**:
The output of a successfully completed ScanJob: one or more raw JPEG images, one per scanned page. Format conversion to PNG, TIFF, or PDF happens at export time — not during scanning.
_Avoid_: Scanned image, output image

**Platen**:
The glass flatbed surface. A ScanJob with a Platen source produces exactly one page.
_Avoid_: Flatbed, glass

**ADF (Automatic Document Feeder)**:
The paper tray that feeds multiple sheets through the Scanner. A ScanJob with an ADF source produces one page per sheet fed, continuing until the feeder is empty.
_Avoid_: Paper feeder, document feeder

**MTOM**:
The multipart MIME encoding used in the Scanner's RetrieveImage response. The SOAP envelope is in part 0; the raw JPEG payload is in part 1.
