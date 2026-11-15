# The full-Platen default ScanRegion was removed on purpose

A Platen ScanJob cannot start until the user has drawn a ScanRegion on the Overview; there is no default. Previously the Overview showed a box covering the whole Platen as soon as it finished, and Scan was enabled whether or not the user had looked at the Overview or chosen an area, so a "scan everything" job could be sent without the user ever deciding that. The default was removed deliberately: after an Overview with no ScanRegion the image is shown plain with a hint, the user drags to draw the box (then moves or resizes it), and Scan stays disabled until a ScanRegion exists (the hint on the preview is the explanation; there is no separate caption under the buttons).

Scanning the whole Platen is still possible, by dragging a box across all of it. An ADF ScanJob is unaffected: it needs no ScanRegion and its ScanTicket carries none, even if one was drawn earlier in the session.

A missing box and a disabled Scan button are therefore intended behaviour, not a regression. Do not restore a full-bed fallback for a nil ScanRegion in the view or in `ScanViewModel`.
