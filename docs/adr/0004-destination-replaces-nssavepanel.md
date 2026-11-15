# Destination replaces NSSavePanel; append extends multi-page PDFs to Platen scans

**Status**: supersedes the save mechanism in [ADR-0001](./0001-output-format-at-save-time.md); extends [ADR-0002](./0002-adf-multi-page-pdf.md)

`NSSavePanel` is removed from the scan-save flow. The Destination (filename, file type, folder, append flag) is set inline in the main window before scanning, and the ScanResult is written automatically the instant the ScanJob completes — there is no manual Save action or dialog. Existing files are never overwritten: if the resolved filename already exists and append is unchecked, the app auto-increments it (`Scan.pdf` → `Scan 2.pdf` → `Scan 3.pdf`) and writes there instead. The writer itself refuses to replace a file, so a file that appears between planning and writing fails the write (the user can retry, which increments again) rather than being lost.

ADR-0001's core reasoning still holds — the Scanner always returns JPEG over the wire, and the ScanTicket stays format-agnostic — but its title is no longer literally accurate: format is now chosen *before* the scan runs, since there's no post-scan dialog left to defer the choice to. The conversion itself still happens at write time, after the JPEG pages are in hand.

This was chosen because a native save panel cannot express "append to an existing document" — appending has to know its target file before conversion happens — and automatic-on-completion save is what makes a fast, repeated-scan workflow possible. The trade-off is accepted deliberately: a bad scan is now written to disk (or appended into an existing PDF) with no review step in between.

Appending also extends ADR-0002: multi-page PDF assembly is no longer implicit to the ADF source. A user can build a multi-page PDF from repeated single-page Platen scans by checking append on each pass and reusing the same Destination filename.

## The folder is chosen each launch and not remembered

The Destination's filename and file type persist across launches; its folder does not. The folder is held in memory only, so every launch starts with none and Scan stays disabled until the user picks one with the folder chooser.

The app is sandboxed. A folder picked in an open panel stays accessible until the app quits under the existing `files.user-selected.read-write` entitlement, but reaching it again after a relaunch would need a security-scoped bookmark and the `files.bookmarks.app-scope` entitlement. One extra click per launch was judged cheaper than carrying bookmark resolution, stale-bookmark handling and a new entitlement. If a write fails because the folder has gone (deleted, or its volume unmounted), the folder is forgotten and the user is asked to choose again.

## Consequences of writing with no review step

- A ScanJob cannot start while the Destination is invalid (no folder, or an empty filename or one containing `/` or `:`), because there would be nowhere to put its ScanResult.
- With the ADF as source the file type is forced to PDF. ADR-0002 made PDF the *default* for the ADF; with no dialog left in which to notice the mistake, a multi-page ScanResult written as PNG would silently keep only page 1, so the choice is removed. The file type chosen for the Platen comes back when the source does.
- One pure planning function decides what a write will do — create, create under an incremented name, or blocked with a reason. The caption under the Destination controls and the write itself both use it, and the write recomputes it, so what the user was told and what happens cannot drift apart.
- When a write fails the pages stay in memory and the user is offered "Retry Save"; nothing is discarded until the next ScanJob or Overview starts.
