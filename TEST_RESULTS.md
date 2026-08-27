# Test Results

**Environment**

| | |
|---|---|
| Machine | Apple silicon (arm64), macOS 26.5 |
| Xcode | 26.6 (build 17F113) |
| Swift | 6.3.3 |
| SDKs | iOS 26.5, macOS 26.5 |
| Simulator runtime | iOS 26.5 (23F77) |
| Dependency | AMSMB2 4.0.3 (resolved from SwiftPM) |
| Signing | Ad-hoc ("Sign to Run Locally"), no Apple Developer team |

Deployment targets under test: **iOS 17.0** and **macOS 14.0**.

---

## Builds

| Target | Destination | Result |
|---|---|---|
| App | `platform=macOS,arch=arm64` | **Pass** — 0 errors, 0 warnings |
| App | `platform=iOS Simulator,name=iPhone 17 Pro` | **Pass** — 0 errors, 0 warnings |
| App | `platform=iOS Simulator,name=iPad Pro 13-inch (M5)` | **Pass** — 0 errors, 0 warnings (clean build, separate derived data) |

A **native Mac target** is used rather than "Designed for iPad". AMSMB2's
`Package.swift` declares native macOS 11+ / iOS 14+ support with real
per-platform conditionals, both below this app's floor, so a single
multiplatform target (`SDKROOT=auto`, `TARGETED_DEVICE_FAMILY=1,2,6`) produces a
genuine Mac app. Rationale is in README ("Platform decisions").

---

## Unit tests

`xcodebuild test -only-testing:SimpleSMBFileBrowserTests` on iPhone 17 Pro
Simulator.

**146 tests executed, 0 failures, 0 skipped.**

| Suite | Tests | Result |
|---|---:|---|
| `SMBServiceTests` | 28 | Pass |
| `DeviceFileServiceTests` | 18 | Pass |
| `KeychainServiceTests` | 11 | Pass |
| `TransferCoordinatorTests` | 11 | Pass |
| `ServerStoreTests` | 11 | Pass |
| `BrowsePathTests` | 11 | Pass |
| `ServerProfileTests` | 11 | Pass |
| `BrowseFailureTests` | 10 | Pass |
| `FileItemTests` | 9 | Pass |
| `SortingTests` | 7 | Pass |
| `TransferCenterTests` | 9 | Pass |
| `TransferModelTests` | 4 | Pass |
| `AppPreferencesTests` | 3 | Pass |
| `RecoveryAppTests` | 3 | Pass |

### SMBService coverage (required cases)

Every case below runs against `MockSMBClient` through the `SMBClient` protocol
seam, so the failure paths are exact and no SMB server is involved.

| Required case | Test | Result |
|---|---|---|
| Connect success | `testConnectSucceeds`, `testConnectIsIdempotent` | Pass |
| Auth failure | `testAuthenticationFailureIsReportedAsSuch` (EACCES → `.authenticationFailed`) | Pass |
| Host unreachable | `testHostUnreachableIsReportedAsSuch` (EHOSTUNREACH) | Pass |
| Timeout | `testTimeoutIsReportedAsTimedOut` (ETIMEDOUT) | Pass |
| List directory | `testListDirectoryReturnsItems`, `testListDirectoryConnectsOnDemand`, `testListDirectoryFailureMapsToNotFound` | Pass |
| Upload | `testUpload`, `testUploadFailureMapsToOutOfSpace` | Pass |
| Download | `testDownloadWritesToDestination` | Pass |
| Delete | `testDeleteFileUsesRemoveFile`, `testDeleteDirectoryRemovesRecursively`, `testDeleteFailureMapsToPermissionDenied` | Pass |
| Rename | `testRenameMovesToSiblingPath`, `testRenameAtRootStaysAtRoot` | Pass |
| Move | `testMove`, `testMoveFailureMapsToAlreadyExists` | Pass |

Also covered beyond the required list: connection refused, invalid profile
short-circuiting before any dial, disconnect/reconnect ordering, share
enumeration, streamed reads, transfer cancellation via the progress handler's
`false` return, and copy progress reporting.

---

## Two defects the tests found

Recorded because both were fixed rather than worked around.

**1. SMB path joins disagreed with AMSMB2's own paths.**
`BrowsePath.appending` returned a relative path when joining onto the share root
(`"Movies"`), while AMSMB2's directory listings report absolute `.pathKey` values
(`"/Movies"`). A path the app constructed and a path the server reported were
therefore not interchangeable. Caught by `testRenameMovesToSiblingPath`. Fixed in
`BrowsePath.appending`; the expectations encoding the old behaviour were updated.

**2. Every Keychain call failed with `errSecMissingEntitlement` (-34018).**
Root cause was `CODE_SIGNING_ALLOWED = NO` in the build settings: with signing
skipped entirely, *no entitlements are applied to the binary at all*. Ad-hoc
signing is now allowed (still not *required*), which makes the entitlements real.
All 11 Keychain tests consequently run against the actual Keychain rather than
skipping. A skip guard for -34018 remains in the suite so the tests degrade
gracefully in an environment that genuinely cannot sign.

**3. The failure modal's Retry swallowed its own failure.** (Found by UI tests.)
Retry called `dismiss()` after retrying, but presentation is driven by
`model.presentedFailure` — so `dismiss()` set that binding back to `nil` and
discarded the fresh failure the retry had just produced. Retrying against a
still-broken server left the user on an empty browser with no explanation. Fixed
by letting the binding drive presentation.
