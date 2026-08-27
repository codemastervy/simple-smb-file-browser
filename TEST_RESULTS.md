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

## Summary

All four suites run against the same commit, after every fix below.

| Suite | Destination | Result |
|---|---|---|
| Unit | iPhone 17 Pro Simulator | **153 passed**, 0 failed, 0 skipped |
| Unit | macOS (arm64) | **153 passed**, 0 failed, 0 skipped |
| UI | iPhone 17 Pro Simulator | **20 passed**, 0 failed, 1 skipped |
| UI | iPad Pro 13-inch (M5) Simulator | **20 passed**, 0 failed, 1 skipped |
| Build | macOS · iPhone Sim · iPad Sim | clean, 0 errors, 0 warnings |

The single skip in each UI suite is the drag *gesture*, which XCUITest cannot
drive; see Known limitations. Everything around it in that test runs and passes.

**Not covered by any of this:** the app has never connected to a real SMB server.
See Known limitations — that gap is structural, not an oversight.

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

**153 tests executed, 0 failures, 0 skipped** — identical on iPhone Simulator and macOS.

| Suite | Tests | Result |
|---|---:|---|
| `SMBServiceTests` | 28 | Pass |
| `DeviceFileServiceTests` | 18 | Pass |
| `KeychainServiceTests` | 11 | Pass |
| `TransferCoordinatorTests` | 11 | Pass |
| `FileTransferPayloadTests` | 7 | Pass |
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

### iPad Pro 13-inch (M5) Simulator

**21 tests: 20 passed, 0 failed, 1 skipped.** The skip is the drag *gesture*
(see Known limitations); the surrounding dual-pane assertions in that test do
run and pass.

The iPad run is the reason three of the seven defects above were found. The
iPhone suite passed while multi-select delete was completely non-functional on
iPad, so the two runs are not interchangeable.

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

Seven, all fixed rather than worked around. Several presented as broken test
code and turned out to be the app.

**1. SMB path joins disagreed with AMSMB2's own paths.**
`BrowsePath.appending` returned a relative path when joining onto the share root
(`"Movies"`), while AMSMB2's listings report absolute `.pathKey` values
(`"/Movies"`). A path the app constructed and a path the server reported were not
interchangeable. Caught by `testRenameMovesToSiblingPath`.

**2. Every Keychain call failed with `errSecMissingEntitlement` (-34018).**
Root cause was `CODE_SIGNING_ALLOWED = NO`: with signing skipped entirely, *no
entitlements are applied to the binary at all*. Reads like a sandbox quirk; was a
build setting. Ad-hoc signing is now allowed (still not required), and all 11
Keychain tests run against the real Keychain instead of skipping.

**3. The failure modal's Retry swallowed its own failure.** Retry called
`dismiss()`, which reset the binding driving presentation and discarded the fresh
failure the retry had just produced. Retrying a still-broken server left the user
on an empty browser with no explanation.

**4. The delete confirmation could not be cancelled with VoiceOver.**
`confirmationDialog` on iOS 26 exposes only its Delete button — the
`.cancel`-role button is absent from the accessibility tree, verified by dumping
the hierarchy while it was presented. A VoiceOver user could confirm a
destructive delete but not back out. Replaced with an `.alert`.

**5. Multi-select delete did nothing at all on iPad.** The batch bar's actions
were bare `Label`s at `.title3`, giving roughly **22×25pt** hit areas — half
Apple's 44pt minimum. On iPhone taps happened to land; on iPad they hit the
surrounding glass panel, so tapping Delete never ran its action and no
confirmation ever appeared. Each action is now a 44×44 frame with an explicit
`contentShape`. This was also an accessibility violation on every platform, not
just an iPad bug.

**6. Browse failures were recorded and never displayed.**
`FileBrowserViewModel.failure` was set on every failed operation — listing,
delete, rename, move, folder creation — and **read by no view**. A delete the
server refused looked identical to one that succeeded, because the listing simply
reloaded unchanged. Remote failures now raise the full-screen modal; on-device
locations get an inline banner.

**7. The pane identifier hid the entire pane.** An intermediate fix put
`.accessibilityIdentifier` on the pane's content container, which makes it a
single accessibility element and swallows every child — the list, the rows and
the batch bar all vanished, breaking three previously-passing iPad tests. The
identifier belongs on the list and grid, namespaced per pane.

### Two wrong diagnoses, recorded honestly

Defect 5 took three attempts. I first blamed stacked `.alert` modifiers and
consolidated them into a single routed alert; then blamed the `.overlay` and
switched to `.safeAreaInset`. Neither was the cause. Both changes were kept
because both are improvements — one presentation modifier per view is correct,
and an inset stops the bar covering the last row — but they were claimed as
fixes before being verified, and they weren't.

The actual cause only emerged from dumping the accessibility hierarchy at the
point of failure, which showed the buttons present and the alert's text entirely
absent. That should have been the first step, not the third.

Also worth stating plainly: had only the iPhone simulator been run, this would
have shipped an iPad build where **you cannot delete or rename a file**. The
iPad run was not a formality.

## Live server test — a blocking finding

Run against a real server for the first time: **Samba 4.19.5-Ubuntu (CasaOS) at a
LAN address, 7 shares, guest access enabled.**

**Result: AMSMB2 cannot authenticate to it at all. The app does not connect.**

Reachability and server-side guest access were both confirmed independently
first, using macOS's own SMB client:

| Check | Tool | Result |
|---|---|---|
| Host up | `ping` | 0% loss |
| SMB listening | `nc -z 445` | open |
| Share enumeration as guest | `smbutil view -g` | **7 shares listed** |
| Guest *access* to a data share | `mount_smbfs -N //guest@host/Files` | **mounted, real files listed** |

So the server is reachable, guest is permitted, and the native client works.
Through AMSMB2 every credential combination fails identically with
`POSIXError` code 1 (**EPERM**) and an empty description:

| user | password | domain | Result |
|---|---|---|---|
| `guest` | *(empty)* | — | EPERM |
| *(empty)* | *(empty)* | — | EPERM |
| `guest` | *(empty)* | `WORKGROUP` | EPERM |
| *(empty)* | *(empty)* | `WORKGROUP` | EPERM |
| `guest` | `guest` | `WORKGROUP` | EPERM |
| `guest` | `x` | — | EPERM |
| unknown user | *(empty)* | — | EPERM |
| unknown user | `anything` | — | EPERM |
| `nobody` | *(empty)* | — | EPERM |
| real-looking user | *(empty)* | — | EPERM |

The unknown-user rows were chosen deliberately to trigger Samba's
`map to guest = Bad User` / `Bad Password` behaviour, which grants guest access
to unrecognised logins. It did not help.

### What the cause is not

- **Not Kerberos.** `AMSMB2.initClient` forces `authentication = .ntlmSsp`.
- **Not signing.** It sets `securityMode = [.enabled]`.
- **Not an empty-password bug in the app.** `Context.password` already converts
  `""` to a NULL password, which is the anonymous path.
- **Not the server.** The native client does guest access on the same share,
  minutes apart, from the same machine.

The remaining explanation is libsmb2's NTLMSSP anonymous/guest session handling.
**AMSMB2 exposes no way to influence it:** `securityMode`, `authentication` and
`seal` are all `internal` on `Context`, with no public passthrough on
`SMB2Manager`, so this cannot be worked around from application code. It needs a
patched or forked AMSMB2.

### What this does and doesn't invalidate

The `SMBClient` seam and everything above it are unaffected — the error
translation worked exactly as designed, mapping EPERM to `.authenticationFailed`
and producing "192.168.68.51 rejected the username or password." That is the
correct message for what the server returned.

But the headline stands: **on this server, with guest credentials, the app
cannot connect.** Whether authenticated (username + password) connections work is
**untested** — no account was available. That is the single most valuable
remaining test.



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

**Drag-and-drop between panes: the gesture is not automatable.** XCUITest
synthesizes the drag — the run log shows the press, the drag and the velocity —
but SwiftUI's `.draggable`/`.dropDestination` session never starts from
synthesized events, so no drop occurs. Four approaches were tried
(`press(forDuration:thenDragTo:)`, the same with
`withVelocity:thenHoldForDuration:`, the `XCUICoordinate` variant, and dragging
onto a concrete row rather than the pane); all deliver the gesture and none
produce a drop. The test asserts everything up to the drop — both panes open, are
independently addressable, and each lists its files — then skips explicitly.
Drop *behaviour* is covered without the gesture by `FileTransferPayloadTests` and
`TransferCoordinatorTests`, which run the same cross-provider transfer a drop
triggers. **The gesture itself has never been executed and needs manual
verification.**

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
