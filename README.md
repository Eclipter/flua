# Flua

A free native live wallpaper app for Apple Silicon Macs running macOS 15 or later. No account, subscription, watermark, or media-count limit. The source is included under the MIT license.

## Use it

Open `Flua.app` and use **Discover** for local featured shelves or **Browse** to filter the full collection. Choose a wallpaper and click **Play Wallpaper**. Mirrored mode plays it across every display; Per Display mode lets each display use a different choice. Use **Create** to import a video straight into the editor, or **Import** for videos, images, video manifest folders, direct manifests, `.zip`, and `.bdpkg` archives. Interactive package runtimes are still unsupported. Imported files are copied into Flua’s library; your originals stay where they are.

Use the inspector to adjust speed, dimming, volume, and image fit. Select Desktop or Lock Screen to change its saved Animated/Still mode; linking copies the desktop choice and keeps subsequent choices and modes together. Play Wallpaper applies the desktop choice. Save Lock Screen Choice stores a choice without applying it to macOS; Apply Saved Wallpapers sends the saved pair and modes to macOS for the targeted displays. Right-click a wallpaper or use **Add to Playlist** to organize it. Create playlists with the **+** beside Playlists, then use **Playlist Options** for that playlist’s interval, shuffle mode, or duplication. Use the previous/next controls for navigation; right-click an item inside a playlist to move it earlier or later. Global rotation defaults, fullscreen pause, battery pause, Low Power Mode pause and login startup are in Settings. Text edits save when you press Return. Combine category, color, motion intensity, resolution and aspect filters in any library view; click inspector tags to open exact-tag results. The inspector shows source media facts and trimmed duration. Manage hidden tags in Settings → Blocked tags; this preserves files, playlists and playback assignments.

The menu-bar icon provides pause/resume, next scene in each active playlist, stop, and quit. Closing the library window keeps wallpapers playing; clicking Flua in the Dock or launching it again reopens the library. **Stop** removes the selected desktop overlays. For native playback, it restores the previous Desktop and Lock Screen wallpapers on the targeted displays and retains saved Flua choices for reapply. **Quit** removes every overlay and reveals your existing system wallpaper. Saved display assignments restore the next time Flua opens.

Data lives in `~/Library/Application Support/Flua/`. The bundle identifier is `local.flua.desktop`. All library data and settings are stored locally; the app does not connect to a remote service. Native fullscreen detection uses the system window inventory; display sleep and session lock pause playback. Procedural scenes render at up to 24 fps with a bounded drawing surface; CPU use varies by scene and display.

## Lock Screen wallpapers

The **Apply Saved Wallpapers** button appears only on macOS 27, in the inspector and in Settings → Lock Screen.

Choose Mirrored or Per Display and the display to target. Use **Play Wallpaper** to save a Desktop choice, or select Lock Screen and click **Save Lock Screen Choice**. Choose Animated or Still for each surface, or enable **Link Desktop and Lock Screen** to keep their selections and modes together. Images remain still in either mode. Click **Apply Saved Wallpapers** to send the saved pair to macOS across existing Spaces. An unassigned surface keeps its system wallpaper. Keep `Flua.app` in a permanent folder.

Native playback continues after Flua quits. A successful apply removes Flua’s desktop overlays on displays receiving a native desktop choice. Applying briefly reloads the user's wallpaper service, requires no administrator password or login item, and saves the previous system store as `NativeWallpaperBackup.plist` inside the library. Unsupported store formats and unavailable saved choices are rejected before changes.

Keep the app and its library in place while a native choice is selected. Use **Stop** to restore the system wallpapers recorded before native Apply. The separate `NativeWallpaperBaseline.plist` survives repeated applies and playback edits. If no usable baseline exists, Stop reports an error and preserves the current system wallpaper; choose another wallpaper in System Settings, then apply Flua again to establish a baseline. Click **Apply Saved Wallpapers** again after changing saved choices or modes. Changes to speed, dimming, fit, trim and the still frame automatically refresh matching active native choices after a short delay, preserving surface modes and other system choices. Native choices do not follow Flua playlists, automatic restoration or Pause. Native Stop prevents automatic playlist advancement for those displays for the rest of the session, until playback is explicitly started again. Sleep/wake, actual idle/screen-saver transitions, physical multiple displays, HDR and other macOS versions remain unverified. This build uses private interfaces and is ad-hoc signed, without notarization.

Use **Settings → Lock Screen → Remove native provider…** to restore the retained system wallpaper baseline wherever Flua is still selected and unregister this copy. Your library and later system choices are preserved; Apply Saved Wallpapers sets it up again. Missing or unsafe baselines require selecting another wallpaper in System Settings before retrying.

## Video editing and portable scenes

Select an imported video and click **Edit and export video…**. Set the trim start/end, choose a thumbnail frame and edit scene metadata. **Save to library** keeps the source intact and saves the playback range. Export writes a trimmed MP4, a preview of up to five seconds, or a PNG thumbnail. Quality presets use AVFoundation’s highest-quality, 1080p, 720p or 480p export settings; **Include audio** controls the exported audio track. Export does not apply the desktop speed, dimming, volume or fit settings. Preview audio is muted. MP4 and PNG exports preserve the source but can replace an existing destination selected in the save dialog.

**Export scene package…** creates a new `.flua` folder with the edited video, thumbnail and a JSON manifest. It can be imported into another Flua library. Existing destination folders are preserved. Packages use a JSON manifest that identifies the video asset and scene metadata.

## Scope

| Capability | Included |
|---|---|
| Loop local videos and display images | Yes; formats supported by macOS |
| Unlimited local scenes, combined filters, tags, favorites | Yes |
| Original animated scenes | Aurora, cosmos, ocean, ember |
| Named playlists, per-playlist timing/shuffle, history, reorder | Yes |
| Video trim, metadata, thumbnail, MP4/preview export | Yes; audio preservation and removal covered by smoke tests |
| Video manifest import and portable scene export | Yes; runtime scene kinds remain unsupported |
| Independent display selection, persistent display identity | Yes; one display tested on this host |
| Speed, dimming, volume, fit/fill | Yes |
| Sleep/lock/fullscreen/battery pause controls | Implemented; real sleep/lock/battery transitions not simulated in verification |
| Menu bar and start at login | Implemented; login registration left to user, not enabled during tests |
| Lock Screen wallpaper | macOS 27; apply local videos and the four scenes directly from Flua to all displays |
| System-audio-reactive, Rive, or Metal scene editor | No |

Flua renders desktop wallpapers in click-through windows. `make build` embeds a sandboxed provider using private macOS wallpaper interfaces. Its catalog contains local videos, images and the four built-in scenes. Lock Screen playback belongs to macOS; the desktop playlist and Pause controls manage Flua’s overlays; Stop also restores native wallpapers when a baseline is available. See [feature status](docs/FEATURES.md) and the [provider documentation](Sources/WallpaperExtension/README.md).

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

Results are saved as `smoke-results.json` and library/editor window screenshots. Screenshots fall back to drawing the app’s own view when this test app lacks screen-capture access; no screen-capture permission is requested. The smoke runner checks actual AVFoundation playback, repeated video loops, pause/resume, desktop Still frames that survive resume without changing the source file, image/video import, all four scene types, desktop window visibility and mouse pass-through, cleanup, unchanged system wallpaper, persistence, trimmed playback/export, audio inclusion/removal, scene package roundtrip, thumbnail export and editor presentation. Library checks also cover import facts, rotated video dimensions, legacy metadata backfill, combined filters, clickable tags and blocked-tag visibility in Discover. `make smoke` generates fresh results under `build/verification/`; a manual launch writes them to the supplied results directory.

Physical multi-monitor behavior, real fullscreen transitions, automatic sleep/wake, battery transitions, and login startup still need real-world validation. The app uses public macOS desktop-window APIs, so OS changes can affect how Spaces or desktop icons interact with overlays.

## Project development

See [development instructions](docs/DEVELOPMENT.md) for commands, folder layout, library storage and validation, and [architecture](docs/ARCHITECTURE.md) for component responsibilities.
