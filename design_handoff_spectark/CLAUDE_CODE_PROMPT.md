# Claude Code Prompt — SpectArk Brand Assets (Mac · iPhone · iPad)

> Copy this file as-is and hand it to Claude Code.

---

## Task
Apply the brand assets of SpectArk (a Time Machine-style backup app) to macOS/iOS/iPadOS. All assets are pre-baked under `design_handoff_spectark/`.

## Absolutely forbidden
1. ❌ Do NOT re-render the wordmark ("SpectArk") with Text/UILabel/SwiftUI — it is baked into the images
2. ❌ Do NOT recolor the "A" separately or recreate the clock/arrow/glass in code
3. ❌ Do NOT bundle the Bricolage Grotesque font (not needed)
4. ❌ Do NOT replace LaunchScreen.storyboard with SwiftUI

## What to do
### ① App icons
```bash
cp -R design_handoff_spectark/AppIcon-iOS.appiconset <App>/Resources/Assets.xcassets/AppIcon.appiconset
cp -R design_handoff_spectark/AppIcon-macOS.appiconset <MacApp>/Assets.xcassets/AppIcon.appiconset
```
> iOS is full-bleed, macOS has margins + rounding — do not mix them up.

### ② iOS/iPadOS launch screen
```bash
rm -rf <App>/Resources/Assets.xcassets/{LaunchScreen,LaunchBackground,LaunchMark}.imageset
cp -R design_handoff_spectark/LaunchScreen.imageset <App>/Resources/Assets.xcassets/
cp design_handoff_spectark/LaunchScreen.storyboard <App>/Resources/LaunchScreen.storyboard
```
Info.plist: `UILaunchStoryboardName=LaunchScreen`. The storyboard contains a single UIImageView (`scaleAspectFill`).

### ③ macOS splash
Use `launch/Mac-Window.png` as the first window / About background:
```swift
Image("Mac-Window").resizable().aspectRatio(contentMode: .fill)
```

### ④ In-app wordmark (dark tone → white by default)
```bash
cp design_handoff_spectark/wordmark/wordmark-white*.png <App>/Resources/Assets.xcassets/
```

### ⑤ Build + simulator cache clear (required for iOS/iPad!)
```bash
xcrun simctl erase "iPad Pro (12.9-inch) (6th generation)"
xcrun simctl erase "iPhone 15 Pro"
```

## Verification
- [ ] iOS icon: full-bleed glass + large clock ring + amber hands (preview/app-icon-1024.png)
- [ ] macOS icon: rounded with margins in the Dock (preview/mac-icon-512.png)
- [ ] Launch: dark + icon + white "SpectArk" with amber "A" (preview/launch-ipad-portrait.png)
- [ ] The storyboard contains exactly one UIImageView
- [ ] Verify after clearing the simulator cache

## One-line summary
> **All you do is drop the baked images into place. iOS is full-bleed, macOS includes margins — do not mix them up.**
