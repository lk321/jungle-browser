# Jungle

Native macOS browser built with SwiftUI and WebKit. The product goal is a calm,
fast workspace with aggressively bounded WebKit memory.

## Commands

```sh
xcodebuild -project jungle.xcodeproj -scheme jungle -configuration Debug build
xcodebuild -project jungle.xcodeproj -scheme jungle -destination 'platform=macOS' test
```

## Architecture

- `Domain/` contains value types and pure address parsing only.
- `Application/` owns workspace state and tab lifecycle policy.
- `Infrastructure/` owns WebKit resources; only `WebViewPool` may retain a `WKWebView`.
- `Presentation/` contains SwiftUI/AppKit adapters and must not own browser state.

## Invariants

- A tab record never retains a web view. Inactive views are snapshotted and released after the configured idle interval.
- Resuming a suspended tab loads its last committed URL. Do not claim that a discarded WebKit process preserves JavaScript or form state.
- Keep WebKit delegates and UI mutations on the main actor.
- Add domain tests for pure lifecycle and URL changes. Keep UI tests focused on visible user flows.

## Style

Use English for code and docs, small focused files, guard clauses, explicit types, and no `Any`, force unwraps, lint suppressions, or hidden global state. Prefer platform APIs over dependencies. Delete replaced code in the same change; do not leave compatibility wrappers or unused abstractions.
