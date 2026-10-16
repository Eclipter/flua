# Experimental Flua wallpaper extension

This is an independently written, compiled prototype of the native macOS wallpaper-provider boundary. It can create a remote Core Animation context backed by an IOSurface, return a snapshot, accept locked/suspended updates, and supply a nonempty settings catalog using Apple's actual private payload classes.

It has **not been registered, selected, or activated by WallpaperAgent**. The renderer supports original bundled gradient, image and looping-video fixtures, plus image/video URLs supplied through the host’s file-wrapper array. The main Flua library is not connected to the system settings catalog yet.

## Build and verify

On a Mac with the Command Line Tools and a macOS 26 or newer SDK:

```sh
./build-and-test.sh
```

An optional first argument selects the build directory. The script builds and ad-hoc signs a separate `.appex`, validates its signature/plist, and runs three standalone tests. It performs no extension registration or wallpaper-store edits.

Verified on arm64 macOS 27.0.1, build 26A434, with the macOS 27 SDK. Deployment target 26.0 is declared but has not been tested on macOS 26. The script builds for the current Mac architecture; Intel execution is unverified.

`provider-self-test` verifies direct acquire, locked/suspended state update, 64×64 snapshot, settings catalog, and invalidation. `wire-proof` verifies acquire, update, 32×32 IOSurface snapshot, desktop/screen-saver catalog, and invalidation through an anonymous NSXPC listener using Apple's runtime protocol and private secure-coding classes. `media-self-test` verifies image/video creation with nonempty Apple file wrappers, rendered-frame changes, looping, suspension/resume, snapshots and cleanup. These file tests run outside the host sandbox: real sandbox authorization is not established. Both wire-test endpoints live in the test process. This validates serialization and interface compatibility; it does not establish system-host acceptance or successful lock-screen display.

The build script writes the bundle and test results under `Built/`. Sources and the generated thumbnail are original Flua material.

## Files

- `EntryPoint.swift`: public ExtensionFoundation `AppExtension` and `ConnectionHandler` entrypoint.
- `Provider.m`: runtime protocol wiring, secure-coding adapters, lifecycle handlers, catalog, and direct tests.
- `MediaRenderer.m/.h`: independent image/video renderer, IOSurface frame delivery, loop handling and scoped-file lifetime.
- `generate-fixtures.m`: creates original still/motion assets for the bundle and tests.
- `wire-proof.m`: independent anonymous-XPC integration test.
- `Info.plist`: separate identifier `org.flua.wallpaper.prototype`, package type `XPC!`, and extension point `com.apple.wallpaper`.
- `PROTOCOL.md`: payload formats, implementation design, and remaining work.

The prototype uses private Apple interfaces discovered in the local system framework. Their names and formats may vary between OS releases. Its ad-hoc signature and current entitlement setup have not been validated for extension-host activation.
