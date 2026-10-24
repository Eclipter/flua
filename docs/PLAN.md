# Remaining work

Current capabilities and limitations are listed in [FEATURES.md](FEATURES.md). This plan contains only unresolved implementation and validation work. Remove completed tasks instead of keeping checked entries; record verified capabilities and evidence in FEATURES.md and the relevant documentation. Community features, profiles, network services and third-party runtime dependencies are outside its scope.

## Real-system validation

Use disposable libraries and matching catalog builds. Follow the [integration and rollback procedure](DEVELOPMENT.md#lock-screen-integration-checks); standalone tests and application smoke do not establish system playback behavior.

- Currently blocked: verify native fullscreen entry/exit pause and resume on multiple physical displays. A second physical display is unavailable; current evidence covers only the built-in display on one Mac.
- Verify native playback through VoiceOver by activating playback controls and Set Wallpapers with a disposable matching-catalog build and rollback procedure.
- Currently blocked: verify independent and linked Desktop/Lock Screen choices, modes, Stop, restart and disconnect/reconnect with multiple physical displays. A second physical display is unavailable. Include automatic playlist advancement while another selected display remains stopped, Desktop assignment routing and restoration.
- Verify sleep/wake and visible provider output across display scaling modes. The recorded display-mode switch does not establish rendering correctness.
- Currently blocked: verify HDR output on suitable hardware. A dedicated HDR display is unavailable; the built-in display's limited HDR capability is insufficient for full HDR validation.
- Verify recovery after revoking a live sandbox token. A separate voluntary lease-release check denied a fresh file open and explicit Apply reacquired scoped playback; it does not revoke a still-active host-issued grant. Automatic provider relaunch was not observed during a 90-second provider-crash check with WallpaperAgent alive. See the [recorded scope](../Sources/WallpaperExtension/README.md#provider-termination-and-released-access-lease); live token revocation and automatic recovery remain unestablished.

Update capability claims only after the relevant checks pass. Keep untested OS versions and hardware explicitly unverified.
