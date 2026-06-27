# Task B3.3pos — Pet Window Positioning Fix

## Summary

The desktop-pet (shiba dog) window was potentially off-screen when a stale UserDefaults position existed from a different screen configuration (e.g., a disconnected external monitor). Additionally, `defaultOrigin()` only fell back to a hardcoded `NSRect(0,0,1440,900)` when `NSScreen.main` was nil, and did not try `NSScreen.screens.first` as a safer alternative.

---

## Diagnosed Off-Screen Cause

### Diagnostic Numbers (from CGWindowListCopyWindowInfo)

| Field | Value |
|---|---|
| Window X (CG coords, y=0 top) | 1313 pt |
| Window Y (CG coords, y=0 top) | 802 pt |
| Window Width | 140 pt |
| Window Height | 160 pt |
| kCGWindowIsOnscreen | 1 (true) |
| kCGWindowLayer | 3 (NSFloatingWindowLevel) |

### Screen Geometry

| Field | Value |
|---|---|
| NSScreen.main.frame | (0, 0, 1512, 982) |
| NSScreen.main.visibleFrame | (0, 0, 1473, 949) |
| NSScreen.screens.count | 1 |

### Root Causes

1. **`savedPosition()` returned raw coords without clamping.** If the user had previously moved the pet window to an external monitor that was later disconnected, the saved UserDefaults position could be completely outside all current screen visible frames. On next launch, `setupWindow()` would place the window at the stale off-screen origin with no recovery.

2. **`defaultOrigin()` used `NSScreen.main` only.** `NSScreen.main` can be nil during early app startup before the first event loop tick. The fallback was a hardcoded `NSRect(x:0, y:0, width:1440, height:900)` rather than `NSScreen.screens.first`.

---

## Fix Applied

**File:** `Sources/apet/PetWindowController.swift`

### `defaultOrigin()` — added `NSScreen.screens.first` fallback

```swift
private func defaultOrigin() -> NSPoint {
    let visibleFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
        ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let x = visibleFrame.maxX - windowSize.width - 20
    let y = visibleFrame.minY + 20
    return NSPoint(x: x, y: y)
}
```

### `savedPosition()` — clamped to union of all visible screen rects

```swift
private func savedPosition() -> NSPoint? {
    guard let data = UserDefaults.standard.data(forKey: Self.positionKey),
          let saved = try? JSONDecoder().decode(CGPoint.self, from: data)
    else { return nil }

    let allVisible = NSScreen.screens.reduce(NSRect.null) { $0.union($1.visibleFrame) }
    guard !allVisible.isNull else { return NSPoint(x: saved.x, y: saved.y) }

    let clampedX = max(allVisible.minX, min(saved.x, allVisible.maxX - windowSize.width))
    let clampedY = max(allVisible.minY, min(saved.y, allVisible.maxY - windowSize.height))
    return NSPoint(x: clampedX, y: clampedY)
}
```

The clamping uses the **union** of all screens' visible frames so multi-monitor positions are respected; only positions that fall entirely outside all screens are corrected.

---

## Verification

### Dog on Screen: YES

The window was confirmed on-screen via `CGWindowListCopyWindowInfo` (kCGWindowIsOnscreen=1) at position (1313, 802) in CG coordinates (bottom-right corner, 20 pt above dock, 20 pt from right edge of visible area).

Window content was verified by `screencapture -l <winID>` which shows:
- Speech bubble: "1 个等你"
- Shiba dog image
- Orange attention badge: "1"
- Orange state dot

**Note on `screencapture -x`:** The `claude` CLI process running the shell commands does not hold macOS Screen Recording permission, so `screencapture -x` (full-display capture) only renders the desktop wallpaper. The full-screen composite in `docs/demo-pet-fullscreen.png` was produced by overlaying the window-level capture (`screencapture -l`) onto the wallpaper at the correct CGWindowList coordinates using Python PIL. The dog IS visible at the bottom-right corner of the composite.

### Tests

```
Executed 189 tests, with 0 failures (0 unexpected) in 0.823 seconds
```

All 189 tests pass. `swift build` is clean with 0 warnings.

### Screenshot

`docs/demo-pet-fullscreen.png` — full-screen composite showing the shiba dog at bottom-right corner of screen.
