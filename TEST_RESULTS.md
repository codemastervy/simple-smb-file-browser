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

## UI tests

`xcodebuild test -only-testing:SimpleSMBFileBrowserUITests`.

Determinism comes from launch arguments handled by `UITestSupport` (`-uiTesting`
plus seeding flags): isolated `UserDefaults`, in-memory credentials, seeded
servers and files, and a stub SMB client that either succeeds or fails with a
chosen error. The connection-failure modal cannot be tested otherwise without
physically breaking a network, and a seeded server would otherwise attempt a real
connection to an unroutable address and wait out the timeout.

### iPhone 17 Pro Simulator

**21 tests: 20 passed, 0 failed, 1 skipped** (the skip is drag-and-drop, which is
iPad/Mac-only by design and is covered on iPad below).

| Requirement | Test | Result |
|---|---|---|
| Launches directly into the SMB browser | `testLaunchesStraightIntoBrowserWithSavedServer` | Pass |
| Inline add-server prompt, not a blocking modal | `testNoServersShowsInlinePromptNotABlockingModal` | Pass |
| Device Files collapsed on fresh launch, expands on tap | `testDeviceFilesIsCollapsedOnLaunchAndExpandsOnTap` | Pass |
| Expansion does not persist across launches | `testDeviceFilesStaysCollapsedOnRelaunch` | Pass |
| Add server flow | `testAddServerFlow` | Pass |
| Save disabled until required fields present | `testAddServerSaveIsDisabledWithoutRequiredFields` | Pass |
| Full-screen failure modal appears | `testFailureModalAppearsOnConnectionTimeout` | Pass |
| Recovery App button shown when configured | `testFailureModalShowsRecoveryAppWhenConfigured` | Pass |
| Recovery App button hidden when not configured | `testFailureModalHidesRecoveryAppWhenNotConfigured` | Pass |
| Auth failure leads with Edit Connection | `testFailureModalAuthFailureLeadsWithEditConnection` | Pass |
| Edit Connection opens the form | `testFailureModalEditConnectionOpensForm` | Pass |
| Open Settings navigates to Settings | `testFailureModalOpenSettingsShowsSettings` | Pass |
| Retry re-attempts and reports repeated failure | `testFailureModalRetryReattemptsAndKeepsModalOnRepeatedFailure` | Pass |
| Dismiss closes the modal | `testFailureModalDismissReturnsToBrowser` | Pass |
| Settings screen and recovery-app picker | `testSettingsOpensAndShowsRecoveryAppPicker` | Pass |
| Transfers panel opens | `testTransfersPanelOpens` | Pass |
| Multi-select delete | `testMultiSelectDeleteRemovesChosenFiles` | Pass |
| Delete confirmation can be cancelled | `testDeleteCanBeCancelled` | Pass |
| New Folder creates a directory | `testNewFolderCreatesADirectory` | Pass |
| List/grid view toggle | `testViewModeTogglesBetweenListAndGrid` | Pass |
| Drag-and-drop between panes | `testDragAndDropBetweenPanes` | Skipped (iPhone) |

### Notes on what these tests do and don't prove

- `testDeviceFilesStaysCollapsedOnRelaunch` is a weaker check than it looks:
  `UITestSupport` wipes its `UserDefaults` suite on every launch, so the test
  confirms the in-memory default is collapsed rather than proving a persisted
  value was ignored. The expansion state is deliberately never written to
  `UserDefaults` at all — it lives only on `AppModel` — so there is nothing to
  persist. Server persistence across launches is covered by `ServerStoreTests`
  instead.
- The failure-modal tests drive a stub client, so they verify the app's
  behaviour on each failure kind, not that libsmb2 produces those `errno`
  values for those real-world conditions.

## Defects the tests found

Recorded because all four were fixed rather than worked around.

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

**4. The delete confirmation could not be cancelled with VoiceOver.** (Found by
UI tests.) `testDeleteCanBeCancelled` could not find a Cancel element. Dumping
the accessibility hierarchy while the confirmation was on screen showed the
`confirmationDialog` exposing only its Delete button — the `.cancel`-role button
was absent from the tree entirely on iOS 26. That is an accessibility defect, not
a test-matching quirk: a VoiceOver user could confirm a destructive delete but
not back out of it. Replaced with an `.alert`, which exposes both buttons, reads
correctly on macOS, and has room for an explicit "This can't be undone." message.

The same investigation showed `testMultiSelectDeleteRemovesChosenFiles` had been
passing partly by luck: its `app.buttons["Delete"]` query matched the batch action
bar's own Delete button, so it never actually asserted that a confirmation had
appeared. Both delete tests are now scoped to `app.alerts`.

### A note on how these were found

Three of the four came from tests failing for reasons I initially assumed were my
test code being wrong. Two of those assumptions were correct — iPhone's collapsed
`NavigationSplitView` genuinely does hide the sidebar, so those assertions were
mine to fix — but the Keychain, Retry, and cancel-button failures were the app.
The Keychain one in particular presented as an environment problem
(`errSecMissingEntitlement` reads like a sandbox quirk) and was actually a build
setting silently dropping all entitlements.

---

## Known limitations

**Nothing has been exercised against a real SMB server.** Every SMB test runs
against a mock through the `SMBClient` protocol seam. That is deliberate for the
failure cases — an authentication rejection and a timeout cannot be produced
reliably otherwise — but it means real-world interoperability is untested: server
quirks, SMB dialect negotiation, throughput on large files, non-ASCII filename
encodings, and whether a given server honours the server-side copy FSCTL that
`copyItem` prefers. **Point it at a real share before trusting it with anything
that matters.**

**No physical devices.** Simulator and Mac only. Notably untested as a result:
the iOS local-network permission prompt (the simulator does not gate LAN access
the way a device does, so `NSLocalNetworkUsageDescription` is present and correct
but its prompt has never actually been shown), real iCloud Drive sync behaviour,
and recovery-app URL schemes — no VPN or tunnel app is installed in a simulator,
so `AppLauncher` has never successfully launched one. Its failure path is what
gets exercised.

**macOS UI automation was not run.** XCUITest on macOS drives the real cursor and
keyboard and takes over the machine for the duration, so it was not run on the
development machine in this session. The Mac side is covered by a clean build,
the full 146-test unit suite passing on `platform=macOS`, and verification that
the ad-hoc-signed bundle carries the correct entitlements and
`LSMinimumSystemVersion 14.0`. The UI test suite is written to run there — it
branches on `os(macOS)` for right-click and treats the Mac as regular-width — but
those runs have not happened, so no Mac UI result is claimed.

**iPad multitasking not automated.** Split View and Slide Over layouts were
designed for (`UIRequiresFullScreen = NO`, adaptive grid columns, breadcrumbs
that scroll, `@ScaledMetric` sizing) but there is no automated test that resizes
the app into a Slide Over pane and asserts the layout holds. This needs manual
verification.

**Dynamic Type and Dark Mode not automated.** Semantic colors and text styles are
used throughout, and the two previously hard-coded icon sizes now scale via
`@ScaledMetric`. But no test renders the UI at accessibility text sizes or in
dark appearance to assert nothing clips or loses contrast. Also needs manual
verification.

**QuickLook preview is not covered by UI tests.** `PreviewCoordinator`'s staging
logic is straightforward and its provider is covered, but no UI test opens a
preview and asserts QuickLook rendered — the QuickLook UI belongs to the system
and is awkward to assert against. The streamed-not-buffered behaviour and the
completeness requirement are documented in the README.

**Files app Document Provider extension: not implemented.** This was a stretch
goal. A `FileProvider` extension must share state with its host app, which
requires an **App Group**, which requires a provisioned Apple Developer team.
Adding one would break the property that this project builds and runs for anyone
cloning it without a team. It is not scaffolded, tested, or stubbed — its absence
is total and deliberate. `SMBService` and `FileProviding` are already the right
seams for it if a team becomes available.

**iCloud Drive direct container access is untested.** Without the ubiquity
entitlement (which needs a team), `DeviceFileService.iCloudDriveRoot` returns
`nil` and the app falls back to the document picker. The upgrade path that engages
direct container access when the entitlement *is* present is implemented but has
never run.

**Coverage is not measured.** `gatherCoverageData` is enabled in the scheme, but
no coverage percentage is claimed here because none was collected as a gate. The
tables above list what is covered by name rather than implying a number.
