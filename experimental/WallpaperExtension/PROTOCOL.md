# Wallpaper provider protocol

This document describes the experimental provider implementation and its standalone tests. It uses private macOS framework interfaces. Real-host selection, scoped fixture access, looping video and Lock Screen motion passed on the tested OS; library integration and broader system validation remain unfinished. See the [feasibility result and restoration procedure](README.md#real-host-feasibility-result).

## Entrypoint and connection

The extension plist declares:

```xml
<key>CFBundlePackageType</key><string>XPC!</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>EXAppExtensionAttributes</key>
<dict><key>EXExtensionPointIdentifier</key><string>com.apple.wallpaper</string></dict>
```

Public `ExtensionFoundation.AppExtension` supplies Swift `main()`, but the executable must start at `_NSExtensionMain` to bootstrap ExtensionFoundation first. The build passes `-Xlinker -e -Xlinker _NSExtensionMain` and retains the Swift entrypoint. `verify-entrypoint.sh` checks both symbols. The Swift configuration uses `ConnectionHandler(onConnection:)`. The handler loads the system WallpaperExtensionKit, obtains the runtime protocol named `WallpaperExtensionKit.WallpaperExtensionXPCProtocol`, and constructs `NSXPCInterface` from it.

The prototype exports an object implementing the protocol selectors and supplies allowed secure-coding classes for the core lifecycle methods. It resumes each accepted connection. A disposable sandbox-signed copy inside a Launch Services-registered app passed WallpaperAgent selection, rendering and lock/unlock updates after correcting the executable entrypoint and download-status reply. Explicit host audit validation is not implemented.

The default build has an ad-hoc signature without sandbox entitlements and is rejected by PlugInKit. The disposable host checks added only `com.apple.security.app-sandbox`; that allowed registration and rendering in a recognized containing app. External image/video access was granted through host-supplied file wrappers, without a broad file-access entitlement.

## Core selectors and reply blocks

These signatures passed the anonymous-XPC integration test:

```objc
- (void)acquireWithId:(id)identifier
              request:(id)creationRequest
                reply:(void (^)(id remoteContext, NSError *error))reply;
- (void)updateWithId:(id)identifier
             request:(id)updateRequest
               reply:(void (^)(NSError *error))reply;
- (void)snapshotWithId:(id)identifier
                  reply:(void (^)(id snapshot, NSError *error))reply;
- (void)invalidateWithId:(id)identifier
                    reply:(void (^)(NSError *error))reply;
- (void)provideSettingsViewModelsWithContentTypes:(id)types
                                            reply:(void (^)(id models, NSError *error))reply;
- (void)isChoiceDownloadedWith:(id)choice
                         reply:(void (^)(NSNumber *downloaded, NSError *error))reply;
```

Raw Objective-C protocol encodings for acquire/update are `v40@0:8@16@24@?32`; snapshot/invalidate/settings are `v32@0:8@16@?24`. The generic block encoding does not establish its arguments by itself; the reply signatures above are exercised by the serialization tests.

The protocol also declares choice-download, choice-add/remove, migration, shuffle, debug, and notification methods. The prototype responds with explicit minimal/no-op/unsupported results for them. Those auxiliary request classes and callbacks have not all been exercised over XPC.

`isChoiceDownloadedWith:reply:` takes `WallpaperChoiceIDXPC` and returns a boxed `NSNumber`, not a primitive `BOOL`. The runtime interface reports the reply signature `v@?@"NSNumber"@"NSError"`. Returning primitive `YES` made NSXPC treat address `0x1` as an object and crash during system selection. The wire test now transfers a real choice ID and verifies the boxed true result; the old implementation fails that test with `SIGSEGV`.

The proxy-side protocol includes `pingWithId:`, `updateSettingsViewModels:reply:`, `requestReadOnlyAccessTo:reply:`, and `invalidateSnapshotsWithReply:`. The prototype does not yet use those host callbacks.

## Secure-coding payloads

Apple's concrete wrapper classes expose `initWithCoder:` and `encodeWithCoder:`. These adapters allow a client to encode the wire format without pretending private Swift value types have a public module or reproducing their binary layout.

| Wrapper class | NSCoder key | Stored value |
| --- | --- | --- |
| `WallpaperIDXPC` | `WallpaperID` | NSData containing JSON `{"id":"UUID"}` |
| `WallpaperChoiceIDXPC` | `WallpaperChoiceID` | NSData containing the JSON choice ID and descriptor |
| `WallpaperUpdateRequestXPC` | `WallpaperUpdateRequest` | NSData containing update JSON |
| `WallpaperRemoteContextXPC` | `UInt32` | NSData containing a JSON number, the CAContext ID |
| `WallpaperSettingsViewModelsXPC` | `WallpaperSettingsViewModels` | NSData containing catalog JSON |
| `WallpaperCreationRequestXPC` | `files`, `cacheDirectory`, `codable` | Array of `NSSecurityScopedURLWrapper`, optional wrapper, NSData containing creation JSON |
| `WallpaperSnapshotXPC` | `surface` | XPC object created by `IOSurfaceCreateXPCObject` |

The JSON wrappers use JSON, not a property list. The anonymous-XPC test exercises `WallpaperCreationRequestXPC` with an empty file array and no cache directory. The direct media test supplies a real `NSSecurityScopedURLWrapper` per image/video URL, checks that encoding the creation request exposes one file URL and that the renderer retains one wrapper until invalidation. Its `startAccessingSecurityScopedResource` leases are balanced on cleanup. A separate real-host probe advertised external fixture URLs in the choice descriptor's `files` array and selected `fileIndex:0`. Direct reading before transfer was denied; host-created image/video sessions then reported one wrapper and one active scope, with video reaching 90 rendered frames and three loops.

Snapshot decoding specifically expects an `NSXPCCoder` and calls `decodeXPCObjectForKey:` for `surface`. A small `NSXPCCoder` subclass can supply that XPC object to construct Apple's real snapshot wrapper. On the receiving side `encodeWithCoder:` exposes the same object, and `IOSurfaceLookupFromXPCObject` recovers its dimensions. This was verified over the anonymous connection.

## Creation/update JSON

A successful creation payload has this structure:

```json
{
  "configuration": "",
  "destination": {
    "size": [640, 360],
    "scaleFactor": 1,
    "colorSpace": "BASE64_OF_BINARY_PLIST",
    "directDisplayID": 1
  },
  "isPreview": true,
  "presentationMode": {"default": {}},
  "activityState": {"active": {}},
  "systemAppearance": {"light": {}},
  "debugBackgrounds": false
}
```

`configuration` is base64-encoded Data. The color-space bytes are the binary property-list serialization of `CGColorSpaceCopyPropertyList`; an ICC profile byte stream failed decoding. `directDisplayID` can be omitted. Updates contain the same destination/state fields but omit `configuration` and `isPreview`.

Swift field metadata established presentation cases `default`, `locked`, and `idle`; activity cases `active` and `suspended`; appearance cases `light` and `dark`. Codable encodes these as single-case objects, not plain strings or numbers. Their original spelling and the default/locked/suspended cases were exercised in decoder/lifecycle tests.

Own media configuration is JSON Data inside the base64 `configuration` field: `{"version":1,"kind":"video","fileIndex":0,"fit":"fill"}`. `kind` also accepts `image`; a `source:"bundle"` choice selects only the original bundled fixture for that kind. Arbitrary file paths are not accepted from JSON. File indices select only host-supplied wrapper URLs.

The prototype preserves supplied size as the layer/surface dimensions. How all real host requests distinguish pixels, points, destination scale, HDR, and display affinity remains a host-integration question. Testing used scale 1 only.

## Remote rendering design

Acquire reads the opaque identifier and creation JSON, allocates a BGRA IOSurface, fills an original gradient, and assigns it to `CALayer.contents`. It calls `+[CAContext remoteContextWithOptions:]`, sets the root layer, flushes the transaction, reads `contextId`, and replies with `WallpaperRemoteContextXPC` containing that UInt32.

The standalone context proof returned a valid context and nonzero ID, with its IOSurface attached. It invalidated the context afterwards. Separately, WallpaperAgent acquired real desktop and preview contexts and snapshots; the user confirmed visible video motion during an actual Lock Screen test.

A session retains its context and layer. Update stores the presentation mode, changes layer speed and suspends or resumes the media renderer. It does not resize the destination surface or apply updated scale, color space or appearance. Snapshot wraps the retained surface. Invalidation disposes the renderer and removes the session; session deallocation calls `CAContext.invalidate`. These handlers run on the main queue. `MediaRenderer.m` feeds original image and video frames into the destination surface using CIContext and AVPlayerItemVideoOutput. It attaches a video output to each AVPlayerLooper clone as that item becomes current; output attachments cannot be assumed to survive cloning. Image fitting and video orientation are handled explicitly. The media tests check changed video pixel checksums, multiple frames, at least one loop, stable paused frames, resumption and scope cleanup.

The prototype logs acquired contexts, numeric locked/idle/suspended flags, frame/loop counts and scope counts without media paths. Frame progress is logged only at frames 2 and 90, and a failed player item is logged once. These diagnostics distinguish a delivered first frame from continued playback during host checks.

## Settings catalog

A nonempty desktop and screen-saver model successfully decoded and roundtripped through XPC. Each model contains `groups`, `refreshPolicy:{"default":{}}`, and `isModificationDisabled:false`. The supplied group and three items use stable Flua IDs, original display text, and the bundled thumbnail. The choices are gradient, original still and original motion; media choices encode the bundled-source configuration.

An item contains `id:{"id":"..."}`, `groupID`, `localizedName`, thumbnail `{"image":{"url":"file:///...png"}}`, `choice`, `contentBadge`, `showInTopLevel`, `sortOrder`, `disposability:{"none":{}}`, and an empty context menu. Video choices use `contentBadge:{"video":{}}` so the settings host treats them as Lock Screen and screen-saver playback. Still choices and the gradient use `{"none":{}}`, which the host keeps on the desktop. The choice contains `id:{"descriptor":{"provider":"org.flua.wallpaper.prototype","files":[],"configuration":""}}`, `localizedDescription`, thumbnail, `isDownloaded:true`, and `options:[]`.

`FSSettingsModel()` is the exact executable example. The decoder accepted the object, and the receiving test found one desktop group and one screen-saver group. When a version 1 catalog is supplied, image and video items under `Media/` are appended to that group; a bad version, an escaped path or a mismatched `root` leaves the three fixtures unchanged. Real-host checks displayed and selected the fixtures, delivered snapshots and created desktop and idle-preview contexts. Theme correctness, live catalog refresh callbacks, video thumbnails and durable production choices remain untested.

## Integration status

1. System selection and frame delivery passed for the original fixtures on the tested OS.
2. Sandboxed access passed for external image/video fixtures using the host's file wrappers.
3. Connect the main Flua library and catalog refresh to the implemented image/video provider sessions.
4. Expand beyond the observed host rendering and brief Lock Screen test: verify actual idle/screen-saver transitions, long-duration locking, multi-display, sleep/wake, and Retina/HDR behavior.
5. Implement settings refresh callbacks and durable library choices using the demonstrated file-wrapper access.
6. Add recovery and restoration only after their state transitions are observed and independently tested.
