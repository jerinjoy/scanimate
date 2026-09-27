# Destination replaces NSSavePanel; append extends multi-page PDFs to Platen scans

**Status**: supersedes the save mechanism in [ADR-0001](./0001-output-format-at-save-time.md); extends [ADR-0002](./0002-adf-multi-page-pdf.md)

`NSSavePanel` is removed from the scan-save flow. The Destination (filename, file type, folder, append flag) is set inline in the main window before scanning, and the ScanResult is written automatically the instant the ScanJob completes — there is no manual Save action or dialog. If the resolved filename already exists and append is unchecked, the app auto-increments it (`Scan.pdf` → `Scan 2.pdf`) rather than overwriting.

ADR-0001's core reasoning still holds — the Scanner always returns JPEG over the wire, and the ScanTicket stays format-agnostic — but its title is no longer literally accurate: format is now chosen *before* the scan runs, since there's no post-scan dialog left to defer the choice to. The conversion itself still happens at write time, after the JPEG pages are in hand.

This was chosen because a native save panel cannot express "append to an existing document" — appending has to know its target file before conversion happens — and automatic-on-completion save is what makes a fast, repeated-scan workflow possible. The trade-off is accepted deliberately: a bad scan is now written to disk (or appended into an existing PDF) with no review step in between.

Appending also extends ADR-0002: multi-page PDF assembly is no longer implicit to the ADF source. A user can build a multi-page PDF from repeated single-page Platen scans by checking append on each pass and reusing the same Destination filename.
