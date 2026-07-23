# SpectArk — Brand Assets (Mac · iPhone · iPad)

> Specta series · Time Machine-style backup app.
> Keeps the family DNA (light glass squircle · blue · amber · Bricolage Grotesque font).
> Icon: large blue clock ring + amber rewind arrow + **amber clock hands**. The wordmark's amber accent is the **"A"**.

## Included assets

```
design_handoff_spectark/
├── README.md · CLAUDE_CODE_PROMPT.md
├── AppIcon-iOS.appiconset/         iOS/iPadOS app icon (full-bleed, 17 sizes)
├── AppIcon-macOS.appiconset/       macOS app icon (margins + rounding, 16–1024)
├── LaunchScreen.storyboard         iOS/iPadOS launch (single UIImageView)
├── LaunchScreen.imageset/          recommended: iPhone/iPad dark variants
├── launch/                          per-orientation imagesets + Mac-Window splash
├── wordmark/                        wordmark-{white,navy}(.2x) · lockup-{white,navy}(.2x)
└── preview/                         app-icon-1024 · mac-icon-512 · launch-ipad-portrait
```

## Platform mapping

| Platform | Icon | Launch / splash |
|---|---|---|
| iOS/iPadOS | `AppIcon-iOS.appiconset` (full-bleed) | `LaunchScreen.imageset` + `LaunchScreen.storyboard` |
| macOS | `AppIcon-macOS.appiconset` (margins + rounding) | `launch/Mac-Window.png` as the first window's background |

After building for iOS/iPad, a **simulator cache clear** (`Erase All Content and Settings`) is required.

## Design tokens

| Token | Value |
|---|---|
| Icon glass body | `#EAF1FB → #D2E0F2 → #BCD0EA` |
| Clock ring | `#4AA3FF → #1A6FE0` |
| Rewind arrow · clock hands | `#FFE066 → #F5B400` (amber) |
| Launch background | radial `#1b2434 → #0c111b → #070a11` |
| Wordmark | white (dark default) / navy (light), **only the "A" in amber** |
| Font | Bricolage Grotesque ExtraBold (baked into images, no bundling needed) |

## Specta series consistency
- Spectalo (play = video) · SpectaLing (waveform = transcription) · **SpectArk (clock rewind = backup)**
- The shared glass · blue · amber · font DNA makes them read as siblings at a glance
