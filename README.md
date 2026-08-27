# Simple SMB File Browser

A multiplatform SwiftUI app for browsing SMB2/3 shares from iPhone, iPad, and Mac,
with the same browser UI over iCloud Drive and on-device files so items can be
moved between a share and the device.

- **Platforms:** iOS 17+, iPadOS 17+, macOS 14+ (single multiplatform target)
- **SMB backend:** [AMSMB2](https://github.com/amosavian/AMSMB2) 4.0.3 (libsmb2)
- **Built and tested with:** Xcode 26.6, Swift 6.3.3 toolchain, iOS 26.5 / macOS 26.5 SDKs

---

## What it does

**Launch behaviour.** The app opens directly into the file browser. There is no
onboarding screen. If a default server is saved, it connects silently in the
background while the browser shows a loading state. With nothing configured, an
inline "Add SMB Server" prompt appears in the detail column — not a modal, so the
sidebar stays usable and Device Files is reachable without ever adding a server.

**Sidebar.** A persistent `NavigationSplitView` sidebar lists saved servers with a
connection status dot (green connected, amber connecting, red failed, grey idle)
and a star on the default. Each row offers Edit, Set as Default, Connect/Disconnect,
Open in Second Pane, and Remove — via context menu everywhere, and via swipe
actions on iOS. Below the servers sits a **Device Files** disclosure group that is
**collapsed on every launch** by design (the expansion state is deliberately not
persisted), containing **iCloud Drive** and **On My iPhone/iPad/Mac**.

**Browsing.** One view serves every location: list and grid modes, sort by
Name/Date Modified/Size/Type ascending or descending (directories always first),
a search field filtering the current directory with an optional recursive toggle,
breadcrumbs on iPad and Mac, a back button on iPhone, pull-to-refresh on iOS and
a toolbar refresh on Mac.

**Operations.** Upload (via the document picker), Download, Rename, Move, Copy,
Delete with confirmation, and New Folder. Multi-select supports batch delete,
move, copy, and download. Name collisions are resolved by de-duplicating
(`report.pdf` → `report 2.pdf`) rather than overwriting.

**Transfers.** Progress with cancellation, plus a Transfers panel showing active
and recent history, and a compact progress strip over the browser while anything
is running.

**Dual pane.** On iPad and Mac, two panes side by side — two shares, or a share
and Device Files — with drag-and-drop between them.

**Connection failures.** A full-screen modal explains what went wrong in plain
language, naming the host: *"Couldn't reach 192.168.1.50 — the connection timed
out."* Actions are ordered by what is most likely to help: a rejected password
leads with **Edit Connection**, a timeout leads with **Open [Recovery App]**, and
**Retry** takes the prominent slot only when neither applies. **Open Settings** is
always offered.

**Settings.** Recovery app (a VPN or tunnel app to launch when a server is
unreachable — a short pre-filled list plus a custom URL scheme, with a Test
button), default view mode and sort order, recursive search and hidden files
defaults, saved-server management, clear transfer history, and an About section.

---

## Setup

Requires Xcode 26 or later on Apple silicon.

```bash
git clone https://github.com/codemastervy/simple-smb-file-browser.git
cd simple-smb-file-browser
open SimpleSMBFileBrowser.xcodeproj
```

The AMSMB2 package resolves automatically on first open; `Package.resolved` is
committed so the dependency graph is pinned.

No Apple Developer team is needed. Everything is **ad-hoc signed** ("Sign to Run
Locally"), which is enough to build, run, and test on all three platforms. To use
your own team, set `DEVELOPMENT_TEAM` and switch `CODE_SIGN_STYLE` to `Automatic`
in `project.yml`, then regenerate.

### Project generation

The `.xcodeproj` is generated from [`project.yml`](project.yml) by
[XcodeGen](https://github.com/yonaskolb/XcodeGen), **and the generated project is
committed** — so the repo opens and builds with no extra tooling. XcodeGen is only
needed if you change the spec:

```bash
xcodegen generate      # after editing project.yml
```

`project.yml` is the source of truth for targets, deployment targets, build
settings, and entitlements. If you add or remove source files outside Xcode,
regenerate.

---

## Build and run

### Mac

```bash
xcodebuild build \
  -project SimpleSMBFileBrowser.xcodeproj \
  -scheme SimpleSMBFileBrowser \
  -destination 'platform=macOS,arch=arm64'
```

Or select **My Mac** in Xcode and run.

### iPhone / iPad Simulator

```bash
xcodebuild build \
  -project SimpleSMBFileBrowser.xcodeproj \
  -scheme SimpleSMBFileBrowser \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

xcodebuild build \
  -project SimpleSMBFileBrowser.xcodeproj \
  -scheme SimpleSMBFileBrowser \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)'
```

If no simulator runtime is installed: `xcodebuild -downloadPlatform iOS`.

### Tests

```bash
# Unit tests
xcodebuild test -project SimpleSMBFileBrowser.xcodeproj \
  -scheme SimpleSMBFileBrowser \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:SimpleSMBFileBrowserTests

# UI tests
xcodebuild test -project SimpleSMBFileBrowser.xcodeproj \
  -scheme SimpleSMBFileBrowser \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:SimpleSMBFileBrowserUITests
```

See [TEST_RESULTS.md](TEST_RESULTS.md) for what was run and what passed.

---

## Architecture

```
SimpleSMBFileBrowser/
├── App/            App entry point, UI-test launch hooks
├── Models/         Value types: FileItem, ServerProfile, BrowseFailure, Transfer…
├── Services/       SMB client, Keychain, device files, transfers, preferences
├── ViewModels/     AppModel (root state), FileBrowserViewModel (one pane)
├── Views/          SwiftUI views
├── Extensions/     Glass materials, cross-platform app launching
└── Resources/      Info.plist, entitlements, asset catalog
```

### The provider seam

The central design decision is `FileProviding`: a protocol describing the
operations a browsable location supports. Two types conform —
`SMBFileProvider` (wrapping `SMBService` → `AMSMB2Client` → `SMB2Manager`) and
`DeviceFileProvider` (wrapping `DeviceFileService` → `FileManager`).

Because both produce the same `FileItem` values and throw the same
`BrowseFailure` errors, `FileBrowserViewModel` and every view are written **once**
and work against a share, iCloud Drive, or local storage without branching. It is
also what makes moving a file from a share to iCloud a normal operation rather
than a special case.

### Testability

`SMBClient` sits between `SMBService` and AMSMB2. That seam exists because the
failure paths matter most and are the hardest to produce on demand: an
authentication rejection, an unreachable host, and a timeout are all
`POSIXError`s thrown from deep inside libsmb2. `MockSMBClient` produces them
exactly, so those tests need no SMB server and no network.

### Error translation

AMSMB2 reports everything as `POSIXError` (it calls `POSIXError.throwIfError` on
libsmb2 return codes) and `FileManager` reports through `NSCocoaErrorDomain`.
`BrowseFailure` is the single place those become sentences a person can act on,
and it also decides which recovery action the failure modal should emphasise.
`EACCES` is mapped differently depending on origin: from a share it means the
server rejected your credentials; from a local file it means file permissions.

### Transfers

`TransferCoordinator` handles copy and move. A same-provider copy is delegated to
the provider (SMB can copy server-side) and a same-provider move is a **rename**,
not copy-then-delete. A cross-provider transfer stages through a local temporary
file, because nothing lets a share write directly into iCloud; read progress maps
to the first half of the progress bar and write to the second, so it doesn't sit
at 100% mid-transfer. Directories recurse, and a source directory is removed only
once everything inside it has arrived.

Cancellation lives in a lock-guarded registry rather than on the main actor,
because AMSMB2 invokes progress callbacks on its own queue and **the callback's
`Bool` return value is the abort signal**.

### Credentials

`ServerProfile` holds only non-secret metadata and is persisted to `UserDefaults`
as JSON. Passwords live in the Keychain keyed by the profile's UUID — keyed by
UUID rather than host/username so renaming a server or changing its user never
orphans a secret, and so serialising a profile cannot leak one. Turning off "Save
Credentials" actively deletes any stored password rather than merely stopping new
writes.

### Liquid Glass

The real Glass APIs (`glassEffect`, `GlassEffectContainer`,
`buttonStyle(.glass)`) are used where available and gated to iOS 26 / macOS 26,
falling back to `.regularMaterial` and `.ultraThinMaterial` on iOS 17–25 and
macOS 14–25. All corners are continuous; depth is a low-contrast shadow that
reads as elevation in both light and dark appearance.

---

## Platform decisions

### Why AMSMB2 on macOS too, rather than native NetFS

macOS could mount a share with NetFS/`NSFileManager` and browse it as a normal
filesystem path. AMSMB2 is used on all three platforms instead, for three
reasons:

1. **One code path.** A NetFS branch would mean two implementations of every
   operation and two sets of failure modes to test, for the one platform where
   SMB is already easiest.
2. **Mounting is user-visible and shared state.** A NetFS mount appears in Finder
   and persists outside the app's lifetime; unmounting can fail while another
   process holds a file. In-process SMB keeps the app's connections its own.
3. **The failure UX is the point.** This app leads with explicit, actionable
   connection errors. `mount_smbfs` surfaces failures as mount errors that are
   harder to map onto specific causes than libsmb2's `POSIXError` codes.

The trade-off: throughput on Mac is bounded by libsmb2 rather than the kernel SMB
client, and shares browsed here do not appear in Finder.

### Native Mac target, not "Designed for iPad"

AMSMB2's `Package.swift` declares native support for macOS 11+ and iOS 14+ with
real per-platform conditionals, both comfortably below this app's floor. A single
multiplatform target (`SDKROOT=auto`, `TARGETED_DEVICE_FAMILY=1,2,6`) therefore
builds a genuine Mac app — with a real sidebar, menu bar, window sizing, and
right-click menus — rather than an iPad app in a compatibility shim.

### Entitlements

Declared in [`SimpleSMBFileBrowser.entitlements`](SimpleSMBFileBrowser/Resources/SimpleSMBFileBrowser.entitlements):

| Entitlement | Why |
|---|---|
| `com.apple.security.app-sandbox` | macOS sandbox (implicit on iOS) |
| `com.apple.security.network.client` | Outbound TCP to the SMB server; without it the Mac sandbox blocks every connection |
| `com.apple.security.files.user-selected.read-write` | Files and folders the user picks, which is how both Device Files locations get access |
| `com.apple.security.files.downloads.read-write` | Download destination |

Two are **deliberately absent**, with reasons recorded inline:

- **iCloud container** (`com.apple.developer.ubiquity-container-identifiers`)
  requires a provisioned Apple Developer team, which would make the project
  unbuildable for anyone cloning it without one. `DeviceFileService` upgrades to
  direct ubiquity-container access automatically when the entitlement is present.
- **Keychain access group** — there is a single app target, so the default
  bundle-id access group suffices; a shared group needs a team identifier prefix
  that ad-hoc signing has no way to supply.

`Info.plist` carries **`NSLocalNetworkUsageDescription`**, which is load-bearing on
iOS 14+: connecting to a LAN address trips the local-network privacy gate, and
without the string the connection fails with no prompt shown at all.

---

## Known limitations

**There is no true "browse the entire device" on iOS or iPadOS.** Apple does not
expose the device filesystem to third-party apps, and no entitlement changes
that. The closest real equivalent is the system's local file domain reached
through the document picker, and that is what this app implements: **On My
iPhone/iPad** starts at the app's own Documents directory (surfaced in the system
Files app via `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`), and
anything outside it is reached only through a user-granted URL from the picker.
On macOS the same location is browsable more freely, but still within the App
Sandbox — arbitrary paths require the user to pick them. This is a platform
constraint, stated here rather than implied away.

**iCloud Drive uses the document picker by default,** not direct container
access, because the ubiquity entitlement needs a paid Developer team (see
Entitlements above). With a team configured, direct access engages automatically.

**QuickLook previews are streamed, not partial.** `PreviewCoordinator` consumes
`FileProviding.readStream` and appends 256 KB chunks to a temporary file, so
previewing a large video costs one chunk of RAM rather than the whole file, and
the operation is cancellable with progress. But QuickLook needs a *complete*
local file to render, so the file does land on disk first. This is chunked,
cancellable staging — not preview of an incomplete file, which QuickLook cannot
do.

**Upload progress totals come from the local file.** AMSMB2's write progress
handler reports bytes written but no total, so upload percentages are computed
against the source file's size read locally.

**Recovery-app URL schemes are best-effort.** Most VPN and tunnel apps do not
publish a stable URL scheme. The pre-filled list is a convenience; a custom
scheme can always be entered, launching never depends on `canOpenURL` (which only
answers for schemes declared in `LSApplicationQueriesSchemes`), and the Test
button in Settings reports whether anything actually handled it.

**No Files app Document Provider extension.** Listed as a stretch goal and not
implemented; see TEST_RESULTS.md.

**Server-side copy depends on the server.** `copyItem` is delegated to AMSMB2;
servers that do not support the relevant FSCTL fall back to its own read/write
loop.

---

## Dependencies

| Package | Version | Purpose |
|---|---|---|
| [AMSMB2](https://github.com/amosavian/AMSMB2) | 4.0.3 | SMB2/3 client (vendors libsmb2) |
| [swift-system](https://github.com/apple/swift-system) | transitive | AMSMB2 dependency |
| [swift-atomics](https://github.com/apple/swift-atomics) | transitive | AMSMB2 dependency |

Build-time only, not a package dependency:
[XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.44.1 — regenerates the
project from `project.yml`.
