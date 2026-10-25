# Remaining work

Current capabilities and limitations are listed in [FEATURES.md](FEATURES.md). This plan contains only unresolved implementation and validation work. Remove completed tasks instead of keeping checked entries; record verified capabilities and evidence in FEATURES.md and the relevant documentation. Apart from the external wallpaper sources planned below, network services remain outside its scope, along with community features, profiles and third-party runtime dependencies.

## Online wallpaper previews and downloads

- Integrate these seven sources into an in-app catalog: [Dareful](https://dareful.com/), [NASA SVS](https://svs.gsfc.nasa.gov/), [Wikimedia Commons](https://commons.wikimedia.org/wiki/Category:Videos), [ISO Republic](https://isorepublic.com/), [Cute Stock Footage](https://cutestockfootage.com/), [Grand Canyon's video archive](https://www.nps.gov/grca/learn/photosmultimedia/b-roll_hd_index.htm), and [Joshua Tree's video archive](https://www.nps.gov/jotr/learn/photosmultimedia/broll.htm). Treat the two National Park Service collections as separate catalog sources.
- Verify each source's current terms, per-clip license, preview rights and supported access/download method before integration. Include only clips already licensed for redistribution without contacting creators; preserve required credits, license links and modification notices. Exclude content needing individual permission, separately restricted audio and sponsored third-party content. Do not assume a public API exists or bypass access restrictions.
- Show thumbnails and playable previews before downloading the full wallpaper, with the source, creator and license visible alongside each item. Keep previews lightweight and avoid downloading full-resolution videos merely to browse.
- Provide a one-click download directly into the local Flua library without requiring a browser or manual file handling. Show progress, cancellation, retry and an already-downloaded state; report unavailable clips clearly. Determine a permitted direct-delivery approach for each source, using a curated catalog where appropriate; identify any source that cannot support this flow before promising integration.
- Validate downloaded media at the import boundary, preserve existing files and persist source/license details with each wallpaper. Downloaded wallpapers must remain usable offline; local library use and playback must continue without a network connection. Keep networking limited to explicit catalog browsing, previews and downloads, without telemetry, accounts or cloud storage.
- Add deterministic coverage for catalog/license metadata, failed and cancelled downloads, duplicate downloads and unsafe or invalid media. Verify browsing, previews, downloads and offline playback in a real app window with a disposable library under the shared system-test lock. Update capability and architecture documentation only when implemented and verified.

## Real-system validation

Use disposable libraries and matching catalog builds. Follow the [integration and rollback procedure](DEVELOPMENT.md#lock-screen-integration-checks); standalone tests and application smoke do not establish system playback behavior.

- Currently blocked: verify native fullscreen entry/exit pause and resume on multiple physical displays. A second physical display is unavailable; current evidence covers only the built-in display on one Mac.
- Currently blocked: verify independent and linked Desktop/Lock Screen choices, modes, Stop, restart and disconnect/reconnect with multiple physical displays. A second physical display is unavailable. Include automatic playlist advancement while another selected display remains stopped, Desktop assignment routing and restoration.
- Currently blocked: verify sleep/wake provider recovery. Active `PreventUserIdleSystemSleep` assertions from runningboardd, sharingd, powerd and ChatGPT prevented a safe sleep transition during the 2026-10-25 check; no power policy was changed. Visible provider output across two built-in Retina scaling modes passed; see the [recorded display results](../Sources/WallpaperExtension/README.md#retina-scaling-and-sleepwake-check).
- Currently blocked: verify HDR output on suitable hardware. A dedicated HDR display is unavailable; the built-in display's limited HDR capability is insufficient for full HDR validation.

Update capability claims only after the relevant checks pass. Keep untested OS versions and hardware explicitly unverified.
