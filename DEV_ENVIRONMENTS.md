# iOS development identity

Debug and Release may coexist. Debug adds `.dev` to the app identity, ` Dev` to the display name and selects `AppIcon-Dev`. Release retains its existing public identity, display name and resources. DevAssets.xcassets is excluded from Release, preserving existing production icons (or their absence).

The Live Activity extension follows the parent prefix: `com.10x.tailview.ios.dev.LiveActivity`. The saved-Mac Keychain service derives from the validated iOS bundle ID; Release retains exactly `com.10x.tailview.ios.saved-macs`. Dev does not import Release pairing records. Pairing mechanisms, token generation, transport, audio and MacHost are unchanged. No new pairing should be performed during identity QA without separate authorization.

## Offline checks

Run `python3 scripts/test-ios-identity.py` from the repository root. This tests Debug/Release environment guards, missing settings, wrong values, cross-environment substitutions, source plist selectors and the 1024x1024 opaque RGB Dev asset.

The Xcode pre-build script rejects a missing/unknown configuration, target, bundle identifier, display name or incorrect icon selection. It makes no network requests and reads no credentials.

On a Mac with Swift, also run `python3 scripts/test-ios-runtime-identity.py`. It compiles the actual identity closure extracted from source into a standalone Foundation fixture, then verifies valid production/dev values and rejection of missing or invalid values. This does not launch the app or use a microphone.

## Required Xcode verification

1. Regenerate the checked-in project: `cd . && xcodegen generate`. Source-only patches are not build-ready until this generated change is included and reviewed.
2. Inspect `xcodebuild -showBuildSettings` for `TailViewIOS` in Debug and Release; confirm bundle ID, display name, icon selection and Release DevAssets exclusion. Use a separate DerivedData path per app/configuration and the shared build wrapper required by the authorized Mac workspace.
3. Build the complete iOS scheme and embedded targets for the approved Simulator destination in both configurations with signing disabled. Do not archive, release, install on physical devices, allow provisioning updates or start paid CI.
4. Run `python3 scripts/verify-built-ios-identity.py --app /path/to/TailViewIOS.app --configuration Debug` against the actual product, then repeat for Release. Supply the actual product path if its filename differs. This inspects installed metadata and compiled icon names without launching.
5. Inspect generated target settings and built entitlements against baseline. No capability, App Group or network/security permission should be added. Before acceptance, verify `DevAssets.xcassets` was omitted from Release asset compilation; the Release artifact must not select or contain Dev-only icon renditions.
6. If Simulator installation/launch is authorized, show side-by-side app names/icons and independent disposable local preferences/files. Do not copy credentials or Release user data. Device coexistence, actual audio, pairing, provider records and background scheduling are not established by these source/build tests.

TailView-specific: build TailViewIOS with its embedded Live Activity; inspect both built bundle IDs and extension display name. Snapshot TailViewMac Debug/Release build settings before/after generation and verify semantic equality. MacHost, Shared and LiveControls must remain unchanged. Never launch the Mac host, connect a viewer, request pairing or exercise remote control/audio for this identity-only verification. Release iOS PNG must retain Git blob 5d52601741b783a9e411454c6f569de0e31f0071.
