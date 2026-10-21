# Remaining work

Current capabilities and limitations are listed in [FEATURES.md](FEATURES.md). This plan contains only unresolved implementation and validation work. Community features, profiles, network services and third-party runtime dependencies are outside its scope.

## Native playback controls

- Connect battery, Low Power Mode and fullscreen pause preferences to native playback, or remove the inactive controls. They currently persist settings without controlling the provider.
- Resolve Pause/Resume behavior: it currently stops automatic playlist advancement, while the selected native wallpaper continues playing.
- Resolve the video Volume control: it currently affects app previews but is not included in native provider configuration.

## Real-system validation

Use disposable libraries and matching catalog builds. Follow the [integration and rollback procedure](DEVELOPMENT.md#lock-screen-integration-checks); standalone tests and application smoke do not establish system playback behavior.

- Verify independent and linked Desktop/Lock Screen choices, modes, Stop, restart and disconnect/reconnect with multiple physical displays. Include automatic Desktop assignment routing and restoration.
- Verify animated scenes during real idle/screen-saver transitions, automatic idle timeout and long-duration locking with Flua closed. Existing scoped results cover video Animated/Still, aurora Still idle transitions and brief aurora Still locking; see the [recorded scope](../Sources/WallpaperExtension/README.md#native-locked-and-idle-transitions).
- Verify sleep/wake, visible provider output across display scaling modes, and HDR output on suitable hardware. The recorded display-mode switch does not establish rendering correctness.
- Verify recovery after revoking a live sandbox token and observe macOS-owned provider relaunch. Fresh wrappers after a permission failure and explicit reapply after termination do not establish those cases.
- Investigate the guarded Stop verification error recorded during active video recovery, despite matching restored store snapshots; see the [recovery result](../Sources/WallpaperExtension/README.md#native-video-recovery).
- Complete VoiceOver interaction checks for search, filters, tags, favorites, playback and blocked tags. Automated accessibility-name checks and the recorded sidebar announcement do not establish the full spoken workflow.

Update capability claims only after the relevant checks pass. Keep untested OS versions and hardware explicitly unverified.
