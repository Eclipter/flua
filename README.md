<p align="center">
  <img src="Resources/AppIcon.png" alt="Flua app icon" width="112">
</p>

<h1 align="center">Flua</h1>

<p align="center">
  Completely free live wallpapers for your Mac Desktop and Lock Screen.
</p>

<p align="center">
  <strong>macOS 27+  </strong>·
  <a href="LICENSE">  MIT license</a>
</p>

## Features

| Feature | Support |
| --- | :---: |
| Live wallpapers | ✅ |
| Create your own wallpapers from images and videos | ✅ |
| Per-display wallpapers | ✅ |
| Lock Screen wallpapers | ✅ |
| Native macOS playback (continues after Flua quits; the previous state can be restored) | ✅ |
| Speed and dimming controls | ✅ |
| Interactive wallpapers | ❌ |
| Audio-reactive wallpapers | ❌ |
| Wallpaper audio | ❌ |
| Wallpaper playlists | ✅ |
| Independent Low Power Mode, low battery and on-battery pauses | ✅ (physical power transitions manually verified by the user) |
| Curate your own local wallpaper library | ✅ |
| Online wallpaper catalog | ❌ |

Distinct Desktop and Lock Screen content uses a pair of wallpapers assigned in Flua. A one-display host check confirmed switching between the built-in cosmos Desktop and ember Still Lock Screen scenes. File-media pairs, mixed-provider pairs and multi-display behavior are not verified.

## Installation

Run in Terminal to install the latest release:

```sh
curl -fsSL https://raw.githubusercontent.com/Eclipter/flua/main/install.sh | bash
```

Updates copy the replacement beside the installed app before swapping it in. If copying fails, the existing installation stays in place; if the final move fails, the installer attempts to restore the previous app and reports its backup location if restoration fails.

## Getting started

1. Use **Add Wallpaper…** to add images, videos or supported packages, or choose a built-in wallpaper.
2. Click a card to select it. Preview and settings appear in the right inspector when the window is at least 1000 points wide. Adjust playback or use **Edit Video…** to trim and choose a cover, then **Save Changes** or **Cancel**.
3. Choose a display mode and target surface in the sidebar, then click **Set Wallpapers** to apply the selected wallpaper to that display and surface. Per Display targets the selected display; Mirrored targets every connected display. Sidebar changes stay in preview until you press the button. Use **Stop** to restore the previous system wallpapers. Opening Flua does not reapply saved wallpapers; start playback explicitly to resume saved playlists.

Open **Settings** from the sidebar or with **Command-comma**. Settings replaces the main content and inspector inside the same window; choose a library section to return.

## Building from source

<details>
<summary>Show build instructions</summary>

Requires Apple’s Swift command-line tools and the macOS 27 SDK. No third-party runtime dependencies.

```sh
git clone https://github.com/Eclipter/flua.git
cd flua
make build
make test
mv build/Flua.app /Applications
open /Applications/Flua.app
```

</details>
