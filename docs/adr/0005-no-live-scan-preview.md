# Live view of the scanner bed during a scan was investigated and rejected

A spinner is shown while a ScanJob is in progress, instead of a live view of the Platen. This was investigated and rejected: WSD's RetrieveImage call returns one complete image in a single blocking response, with no progressive or partial data and no separate preview/status endpoint to poll. The Platen itself has nothing to display mid-pass — there's no camera, only a scan head under the lid. A live view isn't achievable with this protocol or hardware, so the spinner stays.
