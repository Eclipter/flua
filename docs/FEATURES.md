# Feature status

Flua provides local desktop wallpapers, a media library and video export. The experimental native provider is built separately from the desktop application.

Planned work below describes future capabilities, not current support. Community features and profiles are outside this plan.

| Area | Support | Validation and remaining work |
|---|---|---|
| Video/image wallpapers | Local videos and images | Playback, looping, pause/resume and overlay cleanup covered by smoke tests |
| Procedural wallpapers | Aurora, cosmos, ocean and ember | Four locally rendered scenes |
| Displays | Mirrored or per-display selection and restoration | Stable display UUIDs; physical multi-display testing remains. Planned: separate desktop and Lock Screen assignments on each display, linked or independent selections, and persistent Animated/Still modes for each surface |
| Library | Discover shelves, browse filters, favorites, tags, search and local persistence | Model and smoke tests; no hosted catalog. Planned: combined category, color, motion intensity, resolution and standard/ultrawide aspect-ratio filters; inspector resolution, file size, duration and date added; clickable tags as search filters; persistent local blocked-tag list to hide matching content |
| Playlists | Per-playlist timing and shuffle, duplication, previous history and reorder | Model scheduling/history and runtime tests |
| Playback controls | Speed, volume, dimming and fit | Live changes and trimmed playback covered by smoke tests |
| Power controls | Sleep/lock, battery, fullscreen and Low Power Mode | Physical power/session transitions still need validation |
| Video editor | Create flow, preview, trim, thumbnail and metadata | Editor presentation and saved edits covered by smoke tests |
| Video export | MP4, quality presets, optional audio, preview and PNG | Duration, audio tracks and thumbnail decoding checked by smoke tests |
| Scene packages | Manifest folders, JSON, ZIP and `.bdpkg` imports; `.flua` folder exports | Roundtrip, path validation and malicious archive tests |
| Native provider | Experimental image/video `.appex` | Standalone lifecycle, XPC serialization and rendering tests; system-host activation, sandbox authorization and Retina/HDR remain unverified. Planned: Flua library integration, System Settings wallpaper exposure, playback after the main app exits, provider setup and recovery; verify actual desktop playback |
| Lock Screen and screen saver | Experimental Lock Screen support | Actual lock/unlock rendering and recovery remain unverified. Planned: animated Lock Screen and screen saver playback; verify actual lock/unlock and idle transitions |
| Interactive scene runtimes | Unsupported | Imports report unsupported scene types |
| Audio-reactive scenes | Unsupported | No system-audio capture or reactive renderer |
| Shared catalog | Unsupported | Libraries and media are local |
| Login startup | Opt-in | Requires user activation; not enabled during tests |

Run `make test` for model and package validation, `make smoke` for application checks, and `make native-test` for the standalone provider. Application smoke results are written to `build/verification/`; provider results are written to `experimental/WallpaperExtension/Built/`. Standalone provider tests do not establish acceptance by the system wallpaper host.
