# Experimental Flua wallpaper extension

This is an independently written, compiled prototype of the native macOS wallpaper-provider boundary. It can create a remote Core Animation context backed by an IOSurface, return a snapshot, accept locked/suspended updates, and supply a nonempty settings catalog using Apple's actual private payload classes.

A sandbox-signed disposable copy passed WallpaperAgent selection, context creation, snapshots and looping video on arm64 macOS 27.0.1 (26A434). A separate probe verified sandboxed access to external image/video fixtures through the host's file wrappers. During a real lock/unlock check, host updates were recorded and the user confirmed visible video motion on the Lock Screen. Actual idle/screen-saver transitions and broader hardware/OS behavior remain unverified. The main Flua library is not connected to the system settings catalog yet, and Flua does not install the prototype.

## Build and verify

From the repository root, on a Mac with the Command Line Tools and a macOS 26 or newer SDK/runtime:

```sh
make native-test
```

Alternatively, run `./experimental/WallpaperExtension/build-and-test.sh`; an optional first argument selects the build directory. The script builds and ad-hoc signs a separate `.appex`, validates its entrypoints and signature/plist, and runs three standalone tests. It performs no extension registration or wallpaper-store edits.

The executable's Mach-O entrypoint must be `_NSExtensionMain`, selected by passing `-Xlinker -e -Xlinker _NSExtensionMain` to `swiftc`. ExtensionFoundation then invokes the retained Swift entrypoint. Starting directly at Swift `main` trapped during real-host initialization. `verify-entrypoint.sh` checks the bootstrap symbol and that Swift `main` survives linking; it rejects an executable built without the linker override.

Verified on arm64 macOS 27.0.1, build 26A434, with the macOS 27 SDK. Deployment target 26.0 is declared but has not been tested on macOS 26. The script builds for the current Mac architecture; Intel execution is unverified.

`provider-self-test` verifies direct acquire, locked/suspended state update, 64×64 snapshot, settings catalog, and invalidation. `wire-proof` verifies acquire, update, 32×32 IOSurface snapshot, desktop/screen-saver catalog, boxed download status, and invalidation through an anonymous NSXPC listener using Apple's runtime protocol and private secure-coding classes. `media-self-test` verifies image/video creation with nonempty Apple file wrappers, rendered-frame changes, looping, suspension/resume, snapshots and cleanup. These standalone tests run outside the host sandbox, and both wire-test endpoints live in the test process. Real-host results are recorded separately below; standalone success alone does not establish system-host acceptance.

The build script writes the bundle and test results under `experimental/WallpaperExtension/Built/` by default. Sources and the bundled thumbnail are original Flua material.

## Integration gate

`make native-test` passes the entrypoint, standalone lifecycle, XPC and image/video checks on arm64 macOS 27.0.1 (26A434), using the macOS 27 SDK. The standalone tests correctly report `systemActivationPerformed: false` and `sandboxAuthorizationVerified: false`. Separate real-host checks established playback and sandbox media access, satisfying the core feasibility gate in `docs/PLAN.md`. Idle/screen-saver transitions remain outstanding. No production catalog bridge, installer or native Desktop/Lock Screen assignment controls are exposed.

### Real-host feasibility result

The tests used only original fixtures, ad-hoc signatures and disposable containing applications. No private Apple entitlement, signing identity, login item or production library was used. The external-file probe used the separate disposable identifier `org.flua.wallpaper.scoped-probe` to avoid reusing the prototype's cached catalog.

| Check | Observed result |
| --- | --- |
| Register the unmodified standalone `.appex` | `pkd` rejected it: `plug-ins must be sandboxed` |
| Sign a disposable copy with `com.apple.security.app-sandbox = true` and register it alone | `pkd` rejected it: `plug-ins outside containing apps must be protected by SIP.` |
| Embed that copy in `FluaHostTest.app/Contents/Extensions/`, sign the app and register the containing app with Launch Services | PlugInKit listed `org.flua.wallpaper.prototype` with the correct parent app |
| WallpaperAgent discovery | The real host called `provideSettingsViewModels` and launched the extension through ExtensionKit |
| Original catalog request, with Swift `main` as the executable entrypoint | The process terminated with `EXC_BREAKPOINT` / `SIGTRAP` in `closure #1 in closure #1 in variable initialization expression of static _EXRunningExtension._shared`, reached from `AppExtension.main()`; WallpaperAgent reported `NSCocoaErrorDomain (4099)` |
| Catalog request after linking with `_NSExtensionMain` as the executable entrypoint | ExtensionFoundation logged a successful service launch; WallpaperAgent completed `provideSettingsViewModels` without the earlier initialization trap |
| Original selection attempt | `isChoiceDownloadedWith:reply:` returned primitive `YES` where NSXPC expected `NSNumber`; the extension crashed with `EXC_BAD_ACCESS` at address `0x1` before acquiring a wallpaper |
| Selection after boxing the download-status reply | System Settings accepted image/video choices; WallpaperAgent completed acquisition, updates and snapshots |
| Bundled video | Desktop and preview sessions each reached 90 rendered frames and three loops |
| External-file negative control | Before receiving wrappers, the sandboxed probe's direct read of the external video fixture failed |
| Host file transfer | External image/video sessions each retained one host wrapper and one active scope; video reached 90 rendered frames and three loops |
| Containing application exit | The disposable executable ran and exited; the extension continued rendering independently |
| Lock/unlock | The user confirmed visible motion on the actual Lock Screen. Host updates changed from `locked=1` at frame 445 / loop 14 to `locked=0` at frame 469 / loop 15 |
| Idle preview | The host requested `idle=1, preview=1`; this is not an actual idle/screen-saver transition |
| Removal | Both test providers and containing apps were unregistered; provider paths matched the baseline and wallpaper choices were restored to the readable test baseline |

The installed Apple wallpaper extension also uses the `_NSExtensionMain` stub as its Mach-O entrypoint and retains a separate Swift `main`. Matching that bootstrap order resolved the initialization trap; returning `@YES` from the download-status callback resolved the selection crash. The wire regression passes the fixed implementation and crashes with `SIGSEGV` against the old primitive reply. No additional entitlement beyond `com.apple.security.app-sandbox` was needed for these host checks.

The observed rendering, scoped access and brief Lock Screen test establish core feasibility on this OS. They do not establish a production installer, library integration, crash recovery, long-duration locking, actual idle/screen-saver transitions, sleep/wake, multi-display or Retina/HDR behavior. The test containing application is a disposable executable, not the main Flua application.

### Repeat the discovery check and restore state

This procedure verifies startup and catalog discovery without selecting another wallpaper. Keep the verification directory outside the repository and retain the original store snapshot until cleanup is verified. Before starting, confirm `pluginkit -m -A -D -v -i org.flua.wallpaper.prototype` has no matches; if it already exists, record and preserve that registration instead of applying this cleanup blindly.

1. Run `make native-test`. Create a fresh directory with `mktemp -d -t flua-native-host`. Save `sw_vers`, the complete output of `pluginkit -m -A -D -v -p com.apple.wallpaper`, and copies of both plists under `~/Library/Application Support/com.apple.wallpaper/Store/`. Record whether `~/Library/Containers/org.flua.wallpaper.prototype` exists. Record the current System Settings page and selected wallpaper. These snapshots contain local settings; keep them out of Git.
2. In that directory, create `FluaHostTest.app/Contents/MacOS/` and `Contents/Extensions/`. Copy the built `FluaWallpaperExtension.appex` into `Contents/Extensions/`; do not modify generated repository output. Create the containing application's `Contents/Info.plist` with `CFBundleIdentifier = org.flua.wallpaper.host-test`, `CFBundleExecutable = FluaHostTest`, `CFBundleName = Flua Host Test`, `CFBundlePackageType = APPL`, `CFBundleVersion = 1` and `LSMinimumSystemVersion = 26.0`. Compile a disposable Swift executable containing `import Foundation` and `print("Flua disposable provider host")` with `xcrun swiftc`, naming the output `Contents/MacOS/FluaHostTest`. The executable need not run for discovery.
3. Create a plist containing only the boolean entitlement `com.apple.security.app-sandbox = true`. Sign the copied extension with `codesign --force --sign - --entitlements <entitlements.plist> <extension-path>`, then sign the containing application with `codesign --force --sign - <app-path>`. This is the tested ad-hoc sandbox setup, not a proven production signature.
4. Register the containing app, then its extension, using the commands below. Set `FLUA_HOST_CHECK_APP` to the absolute disposable app path first.

```sh
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$FLUA_HOST_CHECK_APP"
pluginkit -a \
    "$FLUA_HOST_CHECK_APP/Contents/Extensions/FluaWallpaperExtension.appex"
pluginkit -m \
    -A -D -vv \
    -i org.flua.wallpaper.prototype
/usr/bin/log show \
    --last 5m \
    --style compact \
    --predicate 'process == "FluaWallpaperExtension" OR (process == "WallpaperAgent" AND eventMessage CONTAINS[c] "org.flua.wallpaper.prototype")' \
    --info --debug
```

5. Inspect System Settings → Wallpaper without selecting anything. If the catalog arrives after the page opens, navigate away and back to refresh it. Verify the Flua group and all three fixture names. Save relevant host logs and any new `FluaWallpaperExtension-*.ips` report from `~/Library/Logs/DiagnosticReports/`. The corrected build completed the catalog request and showed the fixtures. Do not interpret registration, connection or catalog delivery as rendered playback. Actual selection needs a separately established restoration procedure.
6. Always unregister the exact disposable extension and containing app, including after failure:

```sh
pluginkit -r \
    "$FLUA_HOST_CHECK_APP/Contents/Extensions/FluaWallpaperExtension.appex"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -u "$FLUA_HOST_CHECK_APP"
pluginkit -m \
    -A -D -v \
    -i org.flua.wallpaper.prototype
```

7. Confirm no prototype matches and compare the complete provider path list with the baseline. Rename the disposable app to a suffix other than `.app` to avoid rediscovery. If this run created the prototype sandbox container, move only that new container into the verification directory after the process exits; preserve any pre-existing container. Return System Settings to its original page. Compare both wallpaper plists structurally with the snapshots. The discovery-only run changed only system-maintained `LastUse` timestamps; playback selection also changed `LastSet`. Leave timestamp updates intact. All choices, configurations and other values must match the intended baseline before claiming restoration.

### Playback, scoped files and restoration

Before selecting a fixture, verify that the baseline image actually exists and is readable. A stale image entry in System Settings can silently fall back to a different picture. Record every Space/display and idle assignment from both store plists, not just the visible selection. If the baseline is invalid, establish an agreed readable baseline before proceeding. Do not overwrite concurrent user changes.

For the external-file check, use a disposable source copy and the separate `org.flua.wallpaper.scoped-probe` identifier in both the extension plist and catalog descriptors. Copy the original still/video fixtures outside the containing application and extension. Change only that copy's media choices to advertise the corresponding file URL in the descriptor's `files` array, and encode `{"version":1,"kind":"video","fileIndex":0,"fit":"fill"}` (or `kind:"image"`) instead of `source:"bundle"`. In the sandboxed catalog handler, attempt a direct read of the external fixture before selection and record whether it succeeds. Build and run the native tests from the disposable copy before registering it. These probe URLs and source changes must not enter the production catalog or Git.

After registration, wait for the catalog reply and refresh the Wallpaper page before choosing a fixture. Verify the launched executable's path in host logs: macOS may retain an old extension record or catalog after a temporary registration is replaced. Reopen System Settings or restart WallpaperAgent after registering the current build if necessary. A selected label alone does not prove the current descriptor was used. For the external fixture, require a failed unscoped read, successful acquisition with `scopedFiles=1, activeScopes=1`, and continued frame/loop progress. The prototype logs frame milestones at 2 and 90 and numeric locked/idle flags. Launch the disposable containing executable and let it exit, then verify continued rendering. An actual Lock Screen check requires the user to unlock the Mac and confirm visible motion; an `idle=1` preview is not a screen-saver test.

Restore test selections before unregistering the provider. UI restoration must be checked against both saved plists; a label change alone can leave a stale assignment in another Space. The verified fallback was to read the user-owned WallpaperAgent PID from `launchctl print gui/$(id -u)/com.apple.wallpaper.agent`, stop that exact process with `SIGSTOP`, atomically replace only test-provider choice dictionaries with their saved baseline values, and terminate the stopped process with `SIGKILL` so launchd restarts it from the restored store. Always release or restart the stopped process on failure. Preserve unrelated values and timestamp updates. Do not disable SIP or unload the protected launch agent. Then unregister the exact test bundles as above, verify both identifiers have no PlugInKit matches, compare provider paths and compare both store plists apart from `LastUse`/`LastSet`. In the playback check `Index_v2.plist` was unchanged and `Index.plist` differed only in those timestamps. A provider group may remain in an already-open Settings page until its cached catalog is refreshed.

## Files

- `EntryPoint.swift`: public ExtensionFoundation `AppExtension` and `ConnectionHandler` entrypoint.
- `verify-entrypoint.sh`: verifies the executable starts at `_NSExtensionMain` and retains Swift `main`.
- `Provider.m`: runtime protocol wiring, secure-coding adapters, lifecycle handlers, catalog, and direct tests.
- `MediaRenderer.m/.h`: independent image/video renderer, IOSurface frame delivery, loop handling and scoped-file lifetime.
- `generate-fixtures.m`: creates original still/motion assets for the bundle and tests.
- `wire-proof.m`: independent anonymous-XPC integration test.
- `Info.plist`: separate identifier `org.flua.wallpaper.prototype`, package type `XPC!`, and extension point `com.apple.wallpaper`.
- `PROTOCOL.md`: payload formats, implementation design, and remaining work.

The prototype uses private Apple interfaces discovered in the local system framework. Their names and formats may vary between OS releases. The disposable ad-hoc sandbox signature was sufficient for the observed startup, scoped media access and rendering on the tested OS; other OS versions remain unverified.
