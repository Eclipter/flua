# Flua

A free native live wallpaper app for Apple Silicon Macs running macOS 15 or later. No account, subscription, watermark, or media-count limit. The source is included under the MIT license.

## Use it

Open `Flua.app`, choose one of the four animated scenes, choose a display, and click **Apply to desktop**. Use **Import** or drag videos/images, video manifest folders, direct manifests or `.zip` archives into the window to add your own media. Interactive package runtimes are still unsupported. Imported files are copied into Flua’s library; your originals stay where they are.

Use the inspector to adjust speed, dimming, volume, and image fit. Right-click a backdrop or use **Add to Playlist** to organize it. Create playlists with the **+** beside Playlists, then use **Playlist Options** for that playlist’s interval, shuffle mode, or duplication. Use the previous/next controls for navigation; right-click an item inside a playlist to move it earlier or later. Global rotation defaults, fullscreen pause, battery pause, Low Power Mode pause and login startup are in Settings. Text edits save when you press Return.

The menu-bar drop icon provides pause/resume, next scene, stop, and quit. Closing the library window keeps wallpapers playing. **Stop** removes the selected desktop overlays. **Quit** removes every overlay and reveals your existing system wallpaper. Per-display selections restore the next time Flua opens.

Data lives in `~/Library/Application Support/Flua/`. The bundle identifier is `local.flua.desktop`. All library data and settings are stored locally; the app does not connect to a remote service. Native fullscreen detection uses the system window inventory; display sleep and session lock pause playback. Procedural scenes render at up to 24 fps with a bounded drawing surface; CPU use varies by scene and display.

## Video editing and portable scenes

Select an imported video and click **Edit and export video…**. Set the trim start/end, choose a thumbnail frame and edit scene metadata. **Save to library** keeps the source intact and saves the playback range. Export creates a new trimmed MP4, a preview of up to five seconds, or a PNG thumbnail. Quality presets select original resolution, 1080p, 720p or 480p; **Include audio** controls the exported audio track. Preview audio is muted.

**Export scene package…** creates a new `.flua` folder with the edited video, thumbnail and a JSON manifest. It can be imported into another Flua library. Existing destination folders are preserved. Packages use a JSON manifest that identifies the video asset and scene metadata.

## Scope

| Capability                                                  | Included                                                                       |
| ----------------------------------------------------------- | ------------------------------------------------------------------------------ |
| Loop local videos and display images                        | Yes; formats supported by macOS                                                |
| Unlimited local scenes, search, tags, favorites             | Yes                                                                            |
| Original animated scenes                                    | Aurora, cosmos, ocean, ember                                                   |
| Named playlists, per-playlist timing/shuffle, history, reorder | Yes                                                                         |
| Video trim, metadata, thumbnail, MP4/preview export         | Yes; audio preservation and removal tested                                     |
| Video manifest import and portable scene export             | Yes; runtime scene kinds remain unsupported                                    |
| Independent display selection, persistent display identity  | Yes; one display tested on this host                                           |
| Speed, dimming, volume, fit/fill                            | Yes                                                                            |
| Sleep/lock/fullscreen/battery pause controls                | Implemented; real sleep/lock/battery transitions not simulated in verification |
| Menu bar and start at login                                 | Implemented; login registration left to user, not enabled during tests         |
| Native animated Lock Screen provider                        | Standalone experimental image/video provider; system activation unverified     |
| System-audio-reactive, Rive, or Metal scene editor          | No                                                                             |

Flua renders desktop wallpapers in click-through windows. A separate experimental image/video provider uses private macOS wallpaper interfaces. Its standalone tests exercise requests, rendering, snapshots and settings, while system-host activation and library integration remain unfinished. See [feature status](docs/FEATURES.md) and the [provider documentation](experimental/WallpaperExtension/README.md).

## Build and verify

Requires Apple’s Swift command-line tools and macOS SDK. There are no downloaded packages or third-party runtime dependencies.

```sh
make build
make test
open build/Flua.app
```

The build script creates an ad-hoc-signed application. The packaged build is for this Apple Silicon Mac, without Apple notarization. To move it permanently, copy `Flua.app` to your own Applications folder.

Runtime verification is opt-in and uses separate library data. Both directories below should be new, disposable paths. It briefly creates a click-through desktop overlay and removes it, preserving the configured system wallpaper.

```sh
open -n build/Flua.app --args \
  --data-dir /absolute/path/to/fresh-test-library \
  --smoke-test /absolute/path/to/fresh-test-results
```

Results are saved as `smoke-results.json` and library/editor window screenshots. Screenshots fall back to drawing the app’s own view when this test app lacks screen-capture access; no screen-capture permission is requested. The verified run checked actual AVFoundation playback, repeated video loops, pause/resume, image/video import, all four scene types, desktop window visibility and mouse pass-through, cleanup, unchanged system wallpaper, persistence, trimmed playback/export, audio inclusion/removal, scene package roundtrip, thumbnail export and editor presentation. Fresh results are generated under `build/verification/`.

Physical multi-monitor behavior, real fullscreen transitions, automatic sleep/wake, battery transitions, and login startup still need real-world validation. The app uses public macOS desktop-window APIs, so OS changes can affect how Spaces or desktop icons interact with overlays.

## Project development

See [development instructions](docs/DEVELOPMENT.md) for commands, folder layout, library storage and validation, and [architecture](docs/ARCHITECTURE.md) for component responsibilities.
