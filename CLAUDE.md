# Claude notes

## UI framework

Prefer SwiftUI for all UI code. Do not introduce `import UIKit` or
`import AppKit` (including `NSViewRepresentable` / `UIViewRepresentable`
wrappers) without asking first — even for a single modifier or helper.
If SwiftUI lacks an API for what's needed, surface the tradeoff and
wait for explicit confirmation before adding a UIKit/AppKit bridge.

Existing intentional exceptions — do not "clean these up" without
asking:

- `Snorecard/AppIconController.swift` — iOS-only alternate-icon
  switching via `UIApplication.setAlternateIconName`, which has no
  SwiftUI equivalent. macOS intentionally has no picker; the
  controller's `apply` / `applyStoredOnLaunch` entry points are
  no-ops there so callers can invoke them unconditionally.
- `Snorecard-macOS/SnorecardApp.swift` `init()` — sets
  `NSWindow.allowsAutomaticWindowTabbing = false` to strip the
  no-op Show Tab Bar / Merge All Windows menu items. SwiftUI
  doesn't expose `NSWindow.tabbingMode`.
