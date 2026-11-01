# MirrorCast brand artwork

`make_svg.py` draws the logo (a phone in front of a display that mirrors it,
with cast waves) as SVG in several framings:

| File | Use |
| --- | --- |
| `mac.svg` | macOS app icon (Big Sur grid: 824 px body, soft shadow) |
| `square.svg` | In-app logo and legacy Android launcher icon |
| `fg.svg` | Android adaptive-icon foreground (inside the 66/108 safe zone) |
| `mono.svg` | Android 13+ themed (monochrome) icon |

`icon-macos.svg` and `logo.svg` are committed copies for quick previews.

To regenerate the PNGs after editing:

```bash
cd tool/brand && python3 make_svg.py && node render.js mac square fg mono
```

Then resize into `macos/Runner/Assets.xcassets/AppIcon.appiconset/` (16–1024 px),
`android/app/src/main/res/mipmap-*/` (launcher 48 dp, foreground and monochrome
108 dp) and `assets/brand/logo.png` (512 px). `render.js` uses Playwright's
Chromium.
