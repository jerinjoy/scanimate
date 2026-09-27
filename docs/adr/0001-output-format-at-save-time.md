# Output format is chosen at save time, not scan time

**Status**: mechanism superseded by [ADR-0004](./0004-destination-replaces-nssavepanel.md) — format is now chosen before the scan runs, via an inline Destination, not in NSSavePanel afterward. The reasoning below (format-agnostic ScanTicket, JPEG-only wire format) still holds.

The scan pipeline always produces raw JPEG pages (one per scanned sheet). The output format — PNG, TIFF, or PDF — is selected by the user in NSSavePanel after the scan completes, not as part of the ScanTicket.

This keeps the ScanJob and its result format-agnostic: the same `[Data]` of JPEG blobs can be exported to any format without re-scanning. It also reflects how the device actually works — the Scanner always returns JPEG via MTOM regardless of what the user ultimately wants to save.

## Considered options

Baking format into the ScanTicket (scan-time choice) was rejected because it creates a false impression that the Scanner supports multiple output formats natively. It does not — the WSD protocol always delivers JPEG. Choosing format at scan time would require either lying to the user about what's happening or silently converting after the fact anyway.
