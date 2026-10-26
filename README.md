<p align="center">
  <picture><source media="(prefers-color-scheme: dark)" srcset="Resources/WordmarkDark.svg"><img src="Resources/Wordmark.svg" alt="Flua" height="112" align="middle"></picture><img src="Resources/AppIconRounded.png" alt="" width="112" height="112" align="middle">
</p>

<p align="center">
  Completely free live wallpapers for your Mac Desktop, Lock Screen and Screen Saver.
</p>

<p align="center">
  <img src="Resources/BadgeMacOS.svg" alt="macOS 27+" height="26" align="middle">
  <a href="LICENSE"><img src="Resources/BadgeLicense.svg" alt="MIT license" height="26" align="middle"></a>
</p>

## • Features •

| Feature | Support |
| --- | :---: |
| Live wallpapers | ✅ |
| Per-display wallpapers | ✅ |
| Lock Screen wallpapers | ✅ |
| Screen Saver wallpapers | ✅ |
| Native macOS playback (continues after Flua quits) | ✅ |
| Speed and dimming controls | ✅ |
| Create your own wallpapers from images and videos | ✅ |
| Interactive wallpapers | ❌ |
| Audio-reactive wallpapers | ❌ |
| Wallpaper audio | ❌ |
| Wallpaper playlists | ✅ |
| Low Power Mode, low battery and on-battery pauses | ✅ |
| Curate your own local wallpaper library | ✅ |
| Online wallpaper downloads | Search and browse 6 live publisher collections |

## • >1 physical displays •

Not tested. It would be nice to receive your feedback and bug reports.

## • Installation •

Run in Terminal to install the latest release:

```sh
curl -fsSL https://raw.githubusercontent.com/Eclipter/flua/main/install.sh | bash
```

## • Building from source •

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
