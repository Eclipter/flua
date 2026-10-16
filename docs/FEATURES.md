# Feature status

Flua provides local desktop wallpapers, a media library and video export. The experimental native provider is built separately from the desktop application.

| Area | Support | Validation and remaining work |
|---|---|---|
| Video/image wallpapers | Local videos and images | Playback, looping, pause/resume and overlay cleanup covered by smoke tests |
| Procedural wallpapers | Aurora, cosmos, ocean and ember | Four locally rendered scenes |
| Displays | Per-display selection and restoration | Stable display UUIDs; physical multi-display testing remains |
| Library | Favorites, tags, search and local persistence | Model and smoke tests |
| Playlists | Timed rotation, shuffle, previous history and reorder | Model scheduling/history and runtime tests |
| Playback controls | Speed, volume, dimming and fit | Live changes and trimmed playback covered by smoke tests |
| Power controls | Sleep/lock, battery, fullscreen and Low Power Mode | Physical power/session transitions still need validation |
| Video editor | Preview, trim, thumbnail and metadata | Editor presentation and saved edits covered by smoke tests |
| Video export | MP4, quality presets, optional audio, preview and PNG | Duration, audio tracks and thumbnail decoding checked by smoke tests |
| Scene packages | Manifest folders, JSON and ZIP imports; `.flua` folder exports | Roundtrip, path validation and malicious archive tests |
| Native provider | Experimental image/video `.appex` | Standalone lifecycle, XPC serialization and rendering tests; system-host activation, sandbox authorization, Retina/HDR and library integration remain |
| Lock Screen | Experimental | Actual lock/unlock rendering and recovery remain unverified |
| Interactive scene runtimes | Unsupported | Imports report unsupported scene types |
| Audio-reactive scenes | Unsupported | No system-audio capture or reactive renderer |
| Shared catalog | Unsupported | Libraries and media are local |
| Login startup | Opt-in | Requires user activation; not enabled during tests |

Run `make test` for model and package validation, `make smoke` for application checks, and `make native-test` for the standalone provider. Application smoke results are written to `build/verification/`; provider results are written to `experimental/WallpaperExtension/Built/`. Standalone provider tests do not establish acceptance by the system wallpaper host.
