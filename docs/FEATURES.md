# Feature status

Flua provides local desktop wallpapers, a media library and video export. The experimental native provider is built separately from the desktop application.

Remaining implementation work is tracked in [PLAN.md](PLAN.md). Community features and profiles are outside its scope.

| Area | Support | Validation and limitations |
|---|---|---|
| Video/image wallpapers | Local videos and images | Playback, looping, pause/resume and overlay cleanup covered by smoke tests |
| Procedural wallpapers | Aurora, cosmos, ocean and ember | Four locally rendered scenes |
| Displays | Mirrored or per-display desktop selection and restoration | Stable display UUIDs. The library can also store a Lock Screen choice, Animated/Still mode and a link between the two surfaces; the app does not apply or show those controls yet. Physical multi-display behavior remains unverified |
| Library | Discover shelves, combined filters, favorites, clickable tags, search, media facts and blocked tags | Model and isolated smoke tests cover category/color/motion/resolution/aspect filters, exact tags, legacy decoding, measured import facts, rotated video, metadata backfill, package classifications and Discover blocking; no hosted catalog |
| Playlists | Per-playlist timing and shuffle, duplication, previous history and reorder | Model scheduling/history and runtime tests |
| Playback controls | Speed, volume, dimming and fit | Live changes and trimmed playback covered by smoke tests |
| Power controls | Sleep/lock, battery, fullscreen and Low Power Mode | Physical power/session transitions remain unverified |
| Video editor | Create flow, preview, trim, thumbnail and metadata | Editor presentation and saved edits covered by smoke tests |
| Video export | MP4, quality presets, optional audio, preview and PNG | Duration, audio tracks and thumbnail decoding checked by smoke tests |
| Scene packages | Manifest folders, JSON, ZIP and `.bdpkg` imports; `.flua` folder exports | Roundtrip, path validation and malicious archive tests |
| Native provider | Experimental image/video `.appex` | Entrypoint, standalone lifecycle, XPC serialization, download-status and rendering tests pass. A disposable sandbox-signed containing app passed real-host selection, context creation, snapshots and looping video on macOS 27.0.1 (26A434). A separate sandboxed probe verified host-wrapped access to external image/video fixtures, with playback independent of the exited containing application. See the [host-check result](../experimental/WallpaperExtension/README.md#real-host-feasibility-result). The Flua library and setup UI are not connected; Retina/HDR remain unverified |
| Lock Screen and screen saver | Test-video motion on the real Lock Screen; screen-saver catalog and idle preview requests | User confirmed visible Lock Screen motion; host lock/unlock updates were recorded. Actual idle/screen-saver transitions, long-duration locking, recovery and other OS versions remain unverified |
| Interactive scene runtimes | Unsupported | Imports report unsupported scene types |
| Audio-reactive scenes | Unsupported | No system-audio capture or reactive renderer |
| Shared catalog | Unsupported | Libraries and media are local |
| Login startup | Opt-in | Requires user activation; not enabled during tests |

Run `make test` for model and package validation, `make smoke` for application checks, and `make native-test` for the standalone provider. Application smoke results are written to `build/verification/`; provider results are written to `experimental/WallpaperExtension/Built/`. Standalone provider tests do not establish acceptance by the system wallpaper host.

## Library filtering and metadata

All library views apply blocked tags, search and selected filters. Different filter groups combine with AND; multiple values within a group combine with OR. Tag buttons use complete tags, trimmed and compared without case sensitivity. Clear filters resets search and browsing filters; it preserves blocked tags. Settings → Blocked tags manages the persistent visibility preference without removing files, favorites, playlist entries or playback assignments.

Search matches title, tags and scene kind. Animated includes videos and procedural scenes; Still includes images. These are browsing filters, not persistent rendering modes. Browse sorts by name or favorites first; playlist views preserve playlist order.

Category accepts user text; the menu includes existing visible categories and Abstract, Nature, Space, Urban and Unknown. Color is derived from the average sRGB thumbnail color and can be edited; it is an approximate classification, not a dominant-color analysis. Motion intensity is Low, Medium, High or Unknown and is curated or explicitly edited/imported rather than inferred from video movement. All missing classifications have an Unknown choice.

Resolution buckets require both the long and short pixel edges to meet 1280×720, 1920×1080, 2560×1440 or 3840×2160; the highest satisfied threshold wins, independent of orientation. Smaller media is Below 720p. Aspect ratio uses width/height: Portrait below 0.95, Square from 0.95 through 1.05, Standard above 1.05 and below 2, and Ultrawide at 2 or above. Media without measurable dimensions uses Unknown.

The inspector shows measured, orientation-corrected dimensions, copied-file size, source duration, trimmed duration when different, and date added. Images have no playback duration; procedural scenes have no source dimensions, file size or source duration. Facts for legacy imports are filled in asynchronously; historical date added remains Unknown. Missing or unreadable media leaves unavailable facts unknown. Packages carry category/color/motion classifications; receiving libraries measure the exported media and record their own import date.
