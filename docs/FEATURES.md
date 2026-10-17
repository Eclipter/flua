# Feature status

Flua provides local desktop wallpapers, a media library and video export. The wallpaper provider is compiled separately and embedded in `Flua.app`.

Remaining implementation work is tracked in [PLAN.md](PLAN.md). Community features and profiles are outside its scope.

| Area | Support | Validation and limitations |
|---|---|---|
| Appearance | Settings → Appearance → Accent color: System (default) or the eight macOS accent colors | Saved with the local library; applies to accent highlights in the library, settings and video editor. Neutral controls, including segmented pickers, retain their native system styling. Existing libraries default to the macOS accent color |
| Menu bar | Single sakura blossom with five filled petals separated by curved transparent gaps | Generated transparent PNG template adapts to the menu bar appearance. The library sidebar shows the same mark at 22 points, tinted with the accent color |
| Video/image wallpapers | Local videos and images | Playback, looping, pause/resume and overlay cleanup covered by smoke tests |
| Procedural wallpapers | Aurora, cosmos, ocean and ember | Four locally rendered scenes. The wallpaper provider draws the same scenes from `catalog.json`; standalone tests cover motion, suspension and Lock Screen Still rendering |
| Displays | Mirrored or per-display desktop selection and restoration | Stable display UUIDs. The library stores a Lock Screen choice, Animated/Still mode and a link between the two surfaces. Desktop Still shows a retained frame for videos and procedural scenes, and the image itself for photos; there is no inspector control for saved surface mode or linking, and the app does not apply the saved Lock Screen assignment. **Apply to Lock Screen** separately sets the selected item on all displays and Spaces. Physical multi-display behavior remains unverified |
| Library | Discover shelves, combined filters, favorites, clickable tags, search, media facts and blocked tags | Model and isolated smoke tests cover category/color/motion/resolution/aspect filters, exact tags, legacy decoding, measured import facts, rotated video, metadata backfill, package classifications and Discover blocking; no hosted catalog |
| Playlists | Per-playlist timing and shuffle, duplication, previous history and reorder | Model scheduling/history and runtime tests |
| Playback controls | Speed, volume, dimming and fit | Live changes and trimmed playback covered by smoke tests |
| Power controls | Sleep/lock, battery, fullscreen and Low Power Mode | Physical power/session transitions remain unverified |
| Video editor | Create flow, preview, trim, thumbnail and metadata | Editor presentation and saved edits covered by smoke tests |
| Video export | MP4, quality presets, optional audio, preview and PNG | Duration, audio tracks and thumbnail decoding checked by smoke tests |
| Scene packages | Manifest folders, JSON, ZIP and `.bdpkg` imports; `.flua` folder exports | Roundtrip, path validation and malicious archive tests |
| Wallpaper provider | Sandboxed provider embedded in `Flua.app` by `make build` | Apply registers the containing app and extension on macOS 27. Videos, images and four scenes are published from the file-only catalog grant; media uses host wrappers. Library-only catalogs and atomic refresh pass standalone/XPC tests. Real-host scoped playback and catalog refresh passed on macOS 27.0.1 (26A434). Private APIs, ad-hoc signing; other OS versions remain unavailable |
| Lock Screen and screen saver | Apply a selected video or scene directly from Flua with **Apply to Lock Screen** | Applies to all displays and Spaces with a still underlying desktop and animated Lock Screen. Uses a validated, backed-up store transaction and guarded WallpaperAgent reload, without opening Settings or relying on its cached catalog. A newly imported video passed the app-button, persisted-choice and real-host scoped-access checks. The user confirmed motion during a real lock/unlock with the direct method. Overlay Stop/Pause and playlists remain separate. Actual idle/screen-saver transitions, long-duration locking, recovery, Retina/HDR and physical multi-display behavior remain unverified |
| Interactive scene runtimes | Unsupported | Imports report unsupported scene types |
| Audio-reactive scenes | Unsupported | No system-audio capture or reactive renderer |
| Shared catalog | Unsupported | Libraries and media are local |
| Login startup | Opt-in | Requires user activation; not enabled during tests |

Run `make test` for model and package validation, `make smoke` for application checks, and `make wallpaper-test` for the standalone provider. Application smoke results are written to `build/verification/`; provider results are written to `Sources/WallpaperExtension/Built/`. Standalone provider tests do not establish acceptance by the system wallpaper host.

## Library filtering and metadata

All library views apply blocked tags, search and selected filters. Different filter groups combine with AND; multiple values within a group combine with OR. Tag buttons use complete tags, trimmed and compared without case sensitivity. Clear filters resets search and browsing filters; it preserves blocked tags. Settings → Blocked tags manages the persistent visibility preference without removing files, favorites, playlist entries or playback assignments.

With macOS Keyboard navigation enabled, use Tab and Shift-Tab to reach filters, search reset, Clear filters, tag buttons and blocked-tag controls. Space opens a filter menu; arrow keys and Return select its values. Tag buttons are below Motion intensity in the right-hand scene details panel, and scroll into view when focused. Space applies a tag or removes an active tag filter. In Settings → Blocked tags, Return submits the text field; Block and Unblock also support Tab and Space. VoiceOver reads Search, each filter menu, Clear search, Clear filters, Filter by tag, Remove tag filter, and Blocked tags.

Search matches title, tags and scene kind. Animated includes videos and procedural scenes; Still includes images. These are browsing filters, not persistent rendering modes. Browse sorts by name or favorites first; playlist views preserve playlist order.

Category accepts user text; the menu includes existing visible categories and Abstract, Nature, Space, Urban and Unknown. Color is derived from the average sRGB thumbnail color and can be edited; it is an approximate classification, not a dominant-color analysis. Motion intensity is Low, Medium, High or Unknown and is curated or explicitly edited/imported rather than inferred from video movement. All missing classifications have an Unknown choice.

Resolution buckets require both the long and short pixel edges to meet 1280×720, 1920×1080, 2560×1440 or 3840×2160; the highest satisfied threshold wins, independent of orientation. Smaller media is Below 720p. Aspect ratio uses width/height: Portrait below 0.95, Square from 0.95 through 1.05, Standard above 1.05 and below 2, and Ultrawide at 2 or above. Media without measurable dimensions uses Unknown.

The inspector shows measured, orientation-corrected dimensions, copied-file size, source duration, trimmed duration when different, and date added. Images have no playback duration; procedural scenes have no source dimensions, file size or source duration. Facts for legacy imports are filled in asynchronously; historical date added remains Unknown. Missing or unreadable media leaves unavailable facts unknown. Packages carry category/color/motion classifications; receiving libraries measure the exported media and record their own import date.
