<p align="center">
  <img src="Resources/AppIcon.png" alt="Flua app icon" width="112">
</p>

<h1 align="center">Flua</h1>

<p align="center">
  Completely free live wallpapers for your Mac displays and Lock Screen.
</p>

<p align="center">
  <strong>macOS 27+  </strong>·
  <a href="LICENSE">  MIT license</a>
</p>

## Features

| Feature                                                                                  | Support |
| ---------------------------------------------------------------------------------------- | :-----: |
| Animated wallpapers                                                                      |   ✅   |
| Create your own wallpapers from images and videos                                        |   ✅   |
| Per-display wallpapers                                                                   |   ✅   |
| Lock Screen wallpapers                                                                   |   ✅   |
| Native macOS playback (continues after Flua quits; the previous state can be restored) |   ✅   |
| Speed, dimming, motion intensity, volume and fit/fill controls                          |   ✅   |
| Interactive wallpapers                                                                   |   ❌   |
| Audio-reactive wallpapers                                                                |   ❌   |
| Wallpaper playlists                                                                      |   ✅   |
| Low Power mode and on-battery pauses                                                     |   ✅   |
| Local storage with no account, subscription, watermark or limits                         |   ✅   |
| Online wallpaper catalog                                                                 |   ❌   |

## Installation

Run in Terminal to install the latest release:

```sh
curl -fsSL https://raw.githubusercontent.com/Eclipter/flua/main/install.sh | bash
```

## Getting started

1. Use **Add Wallpaper…** to add images, videos or supported packages, or choose a built-in wallpaper.
2. Click a card to preview it. Adjust playback or use **Edit Video…** to trim and choose a cover, then **Save Changes** or **Cancel**.
3. Choose the display and **Desktop** / **Lock Screen**, then click **Set Wallpaper**. Use **Stop** to restore the previous system wallpapers.

**Wallpapers** combines search and sorting with **All / Built-in / Imported** filters. Adding files reveals the result and offers **Undo**. Global adding changes only the library; **Add Wallpapers…** in a playlist selects existing wallpapers or adds files to that playlist. Use **Export Wallpaper…** in a video's context menu to transfer it as a portable package.

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
