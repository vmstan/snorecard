# Claude notes

## UI framework

Prefer SwiftUI for all UI code. Do not introduce `import UIKit` or
`import AppKit` (including `NSViewRepresentable` / `UIViewRepresentable`
wrappers) without asking first — even for a single modifier or helper.
If SwiftUI lacks an API for what's needed, surface the tradeoff and
wait for explicit confirmation before adding a UIKit/AppKit bridge.

Existing intentional exceptions — do not "clean these up" without
asking:

- `Snorecard/AppIconController.swift` — alternate-icon switching has
  no SwiftUI equivalent on either platform (`UIApplication.setAlternateIconName`
  on iOS, `NSApp.applicationIconImage` on macOS).
- `Snorecard-macOS/SnorecardApp.swift` `init()` — sets
  `NSWindow.allowsAutomaticWindowTabbing = false` to strip the
  no-op Show Tab Bar / Merge All Windows menu items. SwiftUI
  doesn't expose `NSWindow.tabbingMode`.
