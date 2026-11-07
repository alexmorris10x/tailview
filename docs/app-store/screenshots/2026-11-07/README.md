# Mac Remote App Store screenshots, 7 November 2026

Landscape sets, because the Mac desktop is landscape: iPhone 6.9" (2868 × 1320) in `iphone-6.9/` and iPad 13" (2752 × 2064) in `ipad-13/`. Both sizes are accepted by App Store Connect. The first three carry the message.

1. **Control your Mac from iPhone** (iPad set: "from iPad"): Your whole Mac desktop, live in your hand.
2. **See and hear your Mac**: Watch the screen and listen to Mac sound, wherever you are.
3. **Keyboard, mouse and trackpad**: Type, click, scroll and drag, with shortcuts and window controls.
4. **Private over your tailnet**: Works with Tailscale. No account and no hosted server in between.
5. **Try 7 days free, then $9.99 once**: No subscription, and nothing is charged automatically.

Background `#6541aa` (the site's violet), white SF Pro headline, the capture in a drawn device frame, in the style of Memex's 3.0 set.

## What the screens are

Every screen is the real iOS app (Mac Remote 1.0.1, which reads "Mac Remote" in-app) on iPhone 17 Pro Max and iPad Pro 13-inch simulators, driven by `ScreenshotUITests/AppStoreScreenshotUITests` through the `TailViewScreenshots` scheme.

- **Sessions (1–3)** run in the Debug build (full access without a purchase) and are real pairings and sessions through the app's own network and streaming code. The Mac end is `tools/demo_mac_host.py`, a stand-in host that speaks the TailView wire protocol from a tailnet machine and streams a prepared demo desktop instead of a real display. A tap on the remote screen (a real click) picks which desktop it streams. Screenshot 3 shows the software keyboard on iPad; on iPhone in landscape the keyboard would cover most of the Mac, so it shows the bar's Command key latched instead. Its frames are the size and JPEG quality the real host sends: 1280 px at 0.55, or 1024 px at 0.42 while Mac sound is on (screenshot 2).
- **The demo desktop** (`tools/compose_desktop.py`) is staged, not one live capture. It uses the macOS Sonoma wallpaper, the real menu bar of the front app with battery, Control Center and a 9:41 clock, a Dock of real app icons, a drawn arrow cursor, and real `screencapture -l` window captures of Keynote, TextEdit and QuickTime Player. Those windows hold neutral demo content: a "Spring Launch Plan" deck on a Keynote theme, a launch checklist, and NASA's public-domain *Earth Views from the ISS* footage. Nobody's private windows, mail, messages or credentials appear.
- **Setup (4)** is the first-run screen before pairing.
- **Access (5)** is the trial and lifetime screen from a Release build (the App Store bundle ID), with the App Store's sandbox prices: 7-day Trial $0.00, Lifetime $9.99.

## Remaking them

1. On a tailnet machine that isn't running the Mac host: `python3 tools/demo_mac_host.py --bind <its 100.x address> --frames keynote.jpg,quicktime.jpg,textedit.jpg`. The frames come from `tools/compose_desktop.py <captures> <out>`. A click in the left, middle or right third of the remote screen picks frame 1, 2 or 3; the test taps there.
2. Set a clean status bar on the simulator (`xcrun simctl status_bar <udid> override --time 9:41 …`).
3. Sessions: `TEST_RUNNER_TV_SHOTS_DIR=<raw dir> TEST_RUNNER_TV_DEMO_HOST=<100.x address> TEST_RUNNER_TV_SHOTS_PART=session ios-dev-build tailview <lane> -- -project TailView.xcodeproj -scheme TailViewScreenshots -configuration Debug -destination 'platform=iOS Simulator,id=<udid>' test`. Access: the same with `TEST_RUNNER_TV_SHOTS_PART=access`, `-configuration Release` and its own lane. Start from a fresh app and keychain (`xcrun simctl uninstall …` and `xcrun simctl keychain <udid> reset`) so the setup screen shows. Captures carry an EXIF orientation that the composer applies.
4. `tools/compose_all.sh iphone|ipad <raw dir>` (Python with Pillow and the SF Pro font).
