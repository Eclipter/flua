# Wallpaper provider protocol

This document describes the experimental provider implementation and its standalone tests. It uses private macOS framework interfaces; system-host activation remains unverified.

## Entrypoint and connection

The extension plist declares:

```xml
<key>CFBundlePackageType</key><string>XPC!</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>EXAppExtensionAttributes</key>
<dict><key>EXExtensionPointIdentifier</key><string>com.apple.wallpaper</string></dict>
```

Public `ExtensionFoundation.AppExtension` supplies `main()`. Its configuration can be `ConnectionHandler(onConnection:)`. The handler loads the system WallpaperExtensionKit, obtains the runtime protocol named `WallpaperExtensionKit.WallpaperExtensionXPCProtocol`, and constructs `NSXPCInterface` from it.

The prototype exports an object implementing the protocol selectors and supplies allowed secure-coding classes for the five tested methods. It resumes each accepted connection. Registration, sandbox/team entitlement acceptance, host audit validation, and system selection are separate steps and remain untested.

The prototype has an ad-hoc signature. Sandbox entitlements and host authorization still need validation.

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
```

Raw Objective-C protocol encodings for acquire/update are `v40@0:8@16@24@?32`; snapshot/invalidate/settings are `v32@0:8@16@?24`. The generic block encoding does not establish its arguments by itself; the reply signatures above are exercised by the serialization tests.

The protocol also declares choice-download, choice-add/remove, migration, shuffle, debug, and notification methods. The prototype responds with explicit minimal/no-op/unsupported results for them. Those auxiliary request classes and callbacks have not all been exercised over XPC.

The proxy-side protocol includes `pingWithId:`, `updateSettingsViewModels:reply:`, `requestReadOnlyAccessTo:reply:`, and `invalidateSnapshotsWithReply:`. The prototype does not yet use those host callbacks.

## Secure-coding payloads

Apple's concrete wrapper classes expose `initWithCoder:` and `encodeWithCoder:`. These adapters allow a client to encode the wire format without pretending private Swift value types have a public module or reproducing their binary layout.

| Wrapper class | NSCoder key | Stored value |
| --- | --- | --- |
| `WallpaperIDXPC` | `WallpaperID` | NSData containing JSON `{"id":"UUID"}` |
| `WallpaperUpdateRequestXPC` | `WallpaperUpdateRequest` | NSData containing update JSON |
| `WallpaperRemoteContextXPC` | `UInt32` | NSData containing a JSON number, the CAContext ID |
| `WallpaperSettingsViewModelsXPC` | `WallpaperSettingsViewModels` | NSData containing catalog JSON |
| `WallpaperCreationRequestXPC` | `files`, `cacheDirectory`, `codable` | Array of `NSSecurityScopedURLWrapper`, optional wrapper, NSData containing creation JSON |
| `WallpaperSnapshotXPC` | `surface` | XPC object created by `IOSurfaceCreateXPCObject` |

The JSON wrappers roundtripped successfully through Apple's real decoders. They use JSON, not a property list. `WallpaperCreationRequestXPC` was initially exercised with an empty file array and no cache directory. The later media test also supplies a real `NSSecurityScopedURLWrapper` per image/video URL, verifies its roundtrip and keeps the wrapper alive until invalidation. Its `startAccessingSecurityScopedResource` leases are balanced on cleanup. This standalone unsandboxed test does not establish authorization in the real extension sandbox.

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

The standalone context proof returned a valid context and nonzero ID, with its IOSurface attached. It invalidated the context afterwards. This confirms local remote-context construction, not that WindowServer displayed it on the lock screen.

A session retains its context and layer. Update stores the presentation mode and changes layer speed for suspension. Snapshot wraps the retained surface. Invalidation releases the session and calls `CAContext.invalidate`. These handlers run on the main queue. `MediaRenderer.m` now feeds original image and video frames into the destination surface using CIContext and AVPlayerItemVideoOutput. It attaches a video output to each AVPlayerLooper clone as that item becomes current; output attachments cannot be assumed to survive cloning. Image fitting and video orientation are handled explicitly. The media tests verify changed pixel checksums, multiple frames, at least one loop, stable paused frames, resumption and scope cleanup.

## Settings catalog

A nonempty desktop and screen-saver model successfully decoded and roundtripped through XPC. Each model contains `groups`, `refreshPolicy:{"default":{}}`, and `isModificationDisabled:false`. The supplied group and three items use stable Flua IDs, original display text, and the bundled thumbnail. The choices are gradient, original still and original motion; media choices encode the bundled-source configuration.

An item contains `id:{"id":"..."}`, `groupID`, `localizedName`, thumbnail `{"image":{"url":"file:///...png"}}`, `choice`, `contentBadge:{"none":{}}`, `showInTopLevel`, `sortOrder`, `disposability:{"none":{}}`, and an empty context menu. The choice contains `id:{"descriptor":{"provider":"org.flua.wallpaper.prototype","files":[],"configuration":""}}`, `localizedDescription`, thumbnail, `isDownloaded:true`, and `options:[]`.

`FSSettingsModel()` is the exact executable example. The decoder accepted the object, and the receiving test found one desktop group and one screen-saver group. This does not prove that System Settings rendered, selected, or correctly themed the catalog. Live catalog refresh, host permission callbacks, previews, video thumbnails, and persistent choices remain untested.

## Remaining integration work

1. Validate the separately signed bundle with the real extension host, without replacing another provider's selection.
2. Establish the correct Flua signing/entitlement/registration setup and inspect any host rejection.
3. Connect the main Flua library and catalog refresh to the implemented image/video provider sessions.
4. Verify actual desktop, locked, idle, screen-saver, preview, multi-display, sleep/wake, and Retina/HDR behavior.
5. Implement settings refresh callbacks and real content choices, including real sandbox authorization and nonempty file transfer through the system host.
6. Add recovery and restoration only after their state transitions are observed and independently tested.
