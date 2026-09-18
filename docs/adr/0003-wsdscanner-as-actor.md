# WSDScanner is a Swift actor

`WSDScanner` is a Swift `actor`, not a class. This has two consequences that are non-obvious from the call sites:

1. **Serial execution is guaranteed by the runtime.** There is no way to start a second ScanJob while one is in progress — the actor serializes all calls automatically. A class-based design would need an explicit `isScanning` guard and a `DispatchQueue` or lock to achieve the same safety.

2. **`activeJobId` is actor-isolated state.** The actor holds the `JobId` of any in-progress ScanJob so that a cancellation request can fire a best-effort `CancelJob` SOAP call. This state must be mutated only from within the actor; the actor boundary enforces that invariant at compile time rather than by convention.
