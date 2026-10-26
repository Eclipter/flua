# Wallpaper provider protocol

This document describes the experimental provider implementation and its standalone tests. It uses private macOS framework interfaces. Earlier real-host checks covered selection, scoped library-video access, looping, catalog refresh and Lock Screen motion for a single content choice. A later one-display real-host check confirmed a v2 cosmos Desktop / ember Still Lock Screen pair through locked/unlocked updates. That result does not cover file media, mixed-provider pairs or multiple displays. The app resolves independent or linked saved surface assignments and modes for targeted displays across existing Spaces. See the [feasibility result and restoration procedure](README.md#real-host-feasibility-result).

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

The standalone prototype build has an ad-hoc signature without sandbox entitlements and is rejected by PlugInKit. `make build` embeds a sandbox-signed copy with identifier `local.flua.desktop.wallpaper` in `Flua.app`. Its only file-read exception is the catalog file; its library-only group omits prototype fixtures. The disposable host checks added only `com.apple.security.app-sandbox`; that allowed registration and rendering in a recognized containing app. External image/video access was granted through host-supplied file wrappers, without a broad file-access entitlement.

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

The proxy-side protocol includes `pingWithId:`, `updateSettingsViewModels:reply:`, `requestReadOnlyAccessTo:reply:`, and `invalidateSnapshotsWithReply:`. The prototype calls `requestReadOnlyAccessTo:` with the catalog file URL when that file is not readable, and `updateSettingsViewModels:` after a granted read or a later write or atomic replacement of the catalog file. It accepts an `NSURL` or `NSSecurityScopedURLWrapper` back and holds the token. `pingWithId:` and `invalidateSnapshotsWithReply:` are still unused.

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

Version 1 remains supported for cached single-content choices: `{"version":1,"kind":"video","fileIndex":0,"fit":"fill","speed":1,"dimming":0,"trim":[0.25,0.75],"still":0.5,"modes":{"desktop":"animated","lockScreen":"still"}}`. Version 2 pairs both Flua surfaces in one descriptor: `{"version":2,"surfaces":{"desktop":{"version":1,"kind":"image","fileIndex":0,"fit":"fill","modes":{"desktop":"animated","lockScreen":"animated"}},"lockScreen":{"version":1,"kind":"video","fileIndex":1,"fit":"fill","modes":{"desktop":"animated","lockScreen":"animated"}}},"playbackPolicy":{"pauseOnBattery":false}}`. Each nested object uses the version 1 media fields. The descriptor's `Files` array is the union of the paired choices' host-supplied wrappers; each nested `fileIndex` addresses that union after Swift remaps its index. Scene entries need no wrapper. The provider rejects incomplete pairs, unsupported kinds, invalid indices and v2 wrappers without file URLs. It never accepts arbitrary paths from JSON. A `source:"bundle"` choice selects only the original bundled fixture for `image` or `video`.

For v2, `default` selects `surfaces.desktop`; `locked` and `idle` select `surfaces.lockScreen`. When that nested configuration differs from the active one, the provider rebuilds the renderer and replaces the layer on the same `CAContext`. `locked` to `idle` reuses the Lock Screen content. The full wrapper union remains retained for the session and recovery. If selected media is temporarily unavailable, the provider shows a static gradient and retries recovery using the currently selected surface config. A v1 descriptor continues to use its single content with its `modes` values. Suspension pauses playback without changing the selected content or mode. `kind` also accepts `aurora`, `cosmos`, `ocean`, `ember`, `ink`, `dunes`, `contour` and `opal`. Missing `speed` is 1 and is clamped to 0.25...2; missing `dimming` is 0 and is clamped to 0...0.85. `fit` is `fit` or `fill`. `trim` is used only when it is two numbers and the end is greater than a non-negative start. `still` is the video frame time, clamped into a valid trim. A scene with no `still` uses 7, the desktop thumbnail time. `modes` accepts `still` or `animated` for `desktop` and `lockScreen`; any other value is Animated. Optional `playbackPolicy` contains boolean `pauseOnBattery`, `pauseOnLowPower`, `pauseOnLowBattery`, `pauseOnFullscreen`, and integer `lowPowerThreshold` (clamped to 0...100). A valid catalog’s top-level policy overrides the descriptor policy for active sessions. The last valid catalog policy survives transient read failures; on a cold start without a valid catalog, the descriptor policy is the fallback. The provider samples managed fullscreen Spaces at 30 Hz and power once per second, combining both with host suspension. Desktop visibility changes therefore do not wait for the next power sample. Previews ignore custom policies. Fullscreen requires `destination.directDisplayID` and affects only `default` presentation; power rules apply to all presentations. Low Power Mode policy pauses on the system setting. Low battery policy independently pauses on an unplugged battery at/below the threshold. A missing `pauseOnLowBattery` inherits `pauseOnLowPower` to preserve legacy policy behavior. Clearing one condition cannot override another or a host pause. Images are a single frame in either mode. Scene Still holds the still time; scene Animated advances at up to 24 fps. Scene drawing uses the desktop cap of 1280 pixels on the long edge, scales each finished frame to the destination, and publishes that full-size surface. Speed and dimming apply. The renderer reads a source file only for image and video, and does not modify it.

The prototype preserves supplied size as the layer and published surface dimensions. Scene drawing uses a smaller buffer only when the destination's long edge exceeds 1280 pixels. How all real host requests distinguish pixels, points, destination scale, HDR, and display affinity remains a host-integration question. Testing used scale 1 only.

## Remote rendering design

Acquire reads the opaque identifier and creation JSON, allocates a BGRA IOSurface, fills an original gradient, and assigns it to `CALayer.contents`. It calls `+[CAContext remoteContextWithOptions:]`, sets the root layer, flushes the transaction, reads `contextId`, and replies with `WallpaperRemoteContextXPC` containing that UInt32.

The standalone context proof returned a valid context and nonzero ID, with its IOSurface attached. It invalidated the context afterwards. Separately, WallpaperAgent acquired real desktop and preview contexts and snapshots; the user confirmed visible video motion during an actual Lock Screen test.

A session retains its context and layer. Update selects the v1 content or the v2 surface config, then applies that content's saved Animated or Still mode. A v2 content change rebuilds the renderer on the same remote context; switching between locked and idle with the same Lock Screen config reuses it. The full wrapper union stays on the session for rebuild and recovery, and renderer leases are balanced as old/new layers are exchanged. Unavailable selected media shows a static gradient and recovery retries the selected config. Suspension does not change the selected content or saved mode. The provider does not resize the destination surface or apply updated scale, color space or appearance. Snapshot wraps the retained surface. A scene frame is copied onto a surface that is not currently displayed, and that surface then becomes the layer contents. Invalidation disposes the renderer and removes the session; session deallocation calls `CAContext.invalidate`. These handlers run on the main queue. `MediaRenderer.m` feeds original image and video frames into the destination surface using CIContext and AVPlayerItemVideoOutput, and draws all eight built-in scenes through `SceneDrawing.swift`. It attaches a video output to each AVPlayerLooper clone as that item becomes current; output attachments cannot be assumed to survive cloning. Image fitting, dimming, video trim, playback speed and orientation are handled explicitly. The media tests check changed video pixel checksums, multiple frames, at least one loop, trim bounds, playback speed, still and animated modes across suspension, locked and idle presentation, stable paused frames, resumption, an unchanged source file and scope cleanup. They also check the paired-image/video source switch, alternate-source fallback and recovery, eight distinct scene frames, scene dimming, scene motion, a suspended animated scene and a locked Still scene. A real-host check on one built-in display confirmed cosmos Desktop and ember Still Lock Screen content in the same Flua session; it does not verify file-media pairs, mixed Flua/non-Flua pairs or multiple displays.

The prototype logs acquired contexts, numeric locked/idle/suspended flags, frame/loop counts and scope counts without media paths. Frame progress is logged only at frames 2 and 90, and a failed player item is logged once. These diagnostics distinguish a delivered first frame from continued playback during host checks.

## Settings catalog

A nonempty desktop and screen-saver model successfully decoded and roundtripped through XPC. Each model contains `groups`, `refreshPolicy:{"default":{}}`, and `isModificationDisabled:false`. The supplied group and three items use stable Flua IDs, original display text, and the bundled thumbnail. The choices are gradient, original still and original motion; media choices encode the bundled-source configuration.

An item contains `id:{"id":"..."}`, `groupID`, `localizedName`, thumbnail `{"image":{"url":"file:///...png"}}`, `choice`, `contentBadge`, `showInTopLevel`, `sortOrder`, `disposability:{"none":{}}`, and an empty context menu. Video choices use `contentBadge:{"video":{}}` so the settings host treats them as Lock Screen and screen-saver playback. Still choices and the gradient use `{"none":{}}`, which the host keeps on the desktop. The choice contains `id:{"descriptor":{"provider":"org.flua.wallpaper.prototype","files":[],"configuration":""}}`, `localizedDescription`, thumbnail, `isDownloaded:true`, and `options:[]`.

`FSSettingsModel()` is the exact executable example. The decoder accepted the object, and the receiving test found one desktop group and one screen-saver group. A catalog is read from `FLUA_CATALOG`, then a bundled `catalog.json`, then the absolute Info.plist string `FLUACatalogPath`, then `~/Library/Application Support/Flua/catalog.json` when the process bundle is an appex. When a version 1 catalog is supplied, image and video items under `Media/` and the eight built-in scene kinds are appended to that group. A scene row needs no readable file; its choice files array is empty and its badge is `video`. Any other kind, a bad version, an escaped path or a mismatched `root` leaves the three fixtures unchanged. Missing scene `still` is written as 7. A catalog row's `speed`, `dimming`, `fit`, `trimStart`, `trimEnd`, `still`, `desktop` and `lockScreen` become the choice configuration above. Missing playback keys use the defaults. When displays disagree, the library writes Animated for that surface; the provider does not resolve the conflict itself. Real-host checks displayed and selected the fixtures, delivered snapshots and created desktop and idle-preview contexts. The anonymous XPC test grants a missing catalog, checks that the pushed screen-saver model contains the library video, and verifies two subsequent atomic replacements. A watcher tracks the catalog file and reopens it when its inode is replaced. Acquire also initializes catalog refresh when the host reused a cached choice without requesting settings. The app build hides the standalone fixtures with `FLUALibraryOnly` and publishes library entries in its own group. Video and scene rows still use the bundled prototype thumbnail. Recorded real-host validation is linked below.

## App integration

`NativeWallpaper.swift` and `NativeWallpaperStore.swift` resolve saved surface assignments, register the embedded provider and apply descriptors through guarded store transactions. Rendering edits automatically refresh matching active choices after a 0.5-second debounce. Stop and confirmed provider removal restore retained system choices; removal then unregisters the exact bundle paths. Native intent persists across launches and display reconnection.

Fallback sessions retry missing or failed media while unsuspended. Fresh host grants require explicit reapply when wrappers are absent or unusable. Explicit Apply also reloads unchanged choices after provider termination; automatic process relaunch is owned by macOS.

See [architecture](../../docs/ARCHITECTURE.md#native-wallpaper-boundary), [recorded host results](README.md#real-host-feasibility-result) and [remaining work](../../docs/PLAN.md).
