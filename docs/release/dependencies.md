# Public-source dependency inventory

Reviewed October 30, 2026 for the initial public release. This is a distribution inventory, not a security audit or a claim that source inspection proves safety.

| Component | Where it enters TailView | Distribution treatment |
| --- | --- | --- |
| Original TailView Swift, scripts, docs, and icon artwork | `MacHost/`, `IOSViewer/`, `Shared/`, extensions and repository assets | Apache 2.0; keep `LICENSE` and `NOTICE` in source and the Mac download. |
| Apple frameworks | Imports of Foundation, SwiftUI, AppKit, UIKit, Security, CryptoKit, CoreGraphics, CoreAudio, AVFoundation, ScreenCaptureKit, ActivityKit, AppIntents, WidgetKit, ServiceManagement, and related system modules | Provided by Apple SDKs/operating systems. No Apple framework source is copied into this repository. The Apache license does not relicense them. |
| Private Apple display interfaces | `MacHost/DisplayControl/BacklightController.swift` and `PhysicalDisplayController.swift` load macOS system symbols at runtime | No framework binary bundled. These interfaces are a compatibility and Mac App Store suitability concern, separate from source-license compatibility. Public Mac distribution is Developer ID/notarization. |
| Tailscale | The user installs Tailscale separately; TailView reads its Mac address and connects over its network | No binary, SDK, or source bundled. Link to Tailscale's download, pricing, terms, and privacy pages. Do not promise that every plan is free or every connection is direct. |
| BlackHole 2ch | Optional separately installed audio device for microphone return | No driver binary or source bundled. Link to the upstream installer and license. Do not put a driver in the DMG or imply the Apache license covers it. |
| XcodeGen | Build-time project generation from `project.yml` | Build tool only, not bundled. Developers install it independently. |
| GitHub Pages actions | `.github/workflows/pages.yml` | External official GitHub build/deploy actions; not embedded in the apps. They run only when the repository is public. |

The checked project has no Swift Package dependencies, CocoaPods, Carthage, JavaScript package tree, or vendored third-party runtime library. No conflicting third-party copyright or copied-license notice was found in the shipped Swift source. This does not independently prove the provenance of every historical contribution: the repository owner is responsible for having the rights to publish it.

Before adding a dependency, record its source/license and required notice here. Do not change repository visibility until private configuration, historical secrets, and any unrelated personal material have been handled by the repository owner. Keep only the original public app source and intended documentation in a public export if repository history cannot be published safely.

References: [Apache 2.0 license](https://www.apache.org/licenses/LICENSE-2.0), [Tailscale](https://tailscale.com/terms), [BlackHole upstream](https://github.com/ExistentialAudio/BlackHole).
