# TailView App Store metadata

**Status (2026-11-07):** Version 1.0 (build `20261030110510`) and both in-app purchases were first submitted to App Review on 7 November 2026 and are **Waiting for Review**, with **automatic release after approval**. This page is the listing as it stands in App Store Connect (read through the API on 7 November 2026); a later submission driven from the repo must start from these values. Actual reinstall/restore, declined Ask to Buy retry, and full setup with the distributed Mac app were still open at submission; see [the remaining work](../TODO.md).

## Listing

- **Name (en-US):** TailView: Remote Desktop Mac
- **Subtitle (en-US):** Control your Mac from iPhone
- **Primary category:** Utilities
- **Secondary category:** Productivity
- **Download price:** Free
- **iOS bundle identifier:** `com.10x.tailview.ios`
- **Minimum OS:** iOS / iPadOS 17
- **Marketing URL:** `https://alexmorris10x.github.io/tailview/`
- **Support URL:** `https://alexmorris10x.github.io/tailview/support.html`
- **Privacy policy URL:** `https://alexmorris10x.github.io/tailview/privacy.html`
- **Copyright:** 2026 Alex Morris
- **Keywords (en-US):** `vnc,screen,sharing,mouse,keyboard,trackpad,access,ipad,audio,tailnet,viewer,away,host,wireguard`

### Spanish (Mexico) localization: second US keyword field

Added 7 November 2026. The US App Store also indexes es-MX, so it carries its own name, subtitle and keywords; its promotional text, description and URLs are the same English text as en-US. Keep it when submitting.

- **Name (es-MX):** TailView: Mac Remote Control
- **Subtitle (es-MX):** Screen share your Mac anywhere
- **Keywords (es-MX):** `rdp,macbook,imac,computer,pc,mirror,stream,connect,vpn,private,secure,phone,iphone,touch,desktop`

Before 7 November the draft listing was "TailView – Remote Mac" / "Your Mac over Tailscale" with keywords `remote,desktop,mac,tailscale,screen,keyboard,mouse,audio,control,ipad`.

### Promotional text

Your Mac, within reach. View its screen, type, click, and listen from your iPhone or iPad over Tailscale. Try 7 days free, then unlock once. No subscription.

### Description

Keep your Mac within reach from your iPhone or iPad.

TailView lets you see and control your Mac's whole desktop over your own Tailscale network. Check a running app, type into a document, or pick up where you left off.

YOUR MAC, ON YOUR DEVICE

• View the Mac's main display, pinch to zoom, and pan around your desktop.
• Click, drag, scroll, type, and send text from your device's clipboard.
• Use modifier keys, keyboard shortcuts, and window controls.
• Listen to Mac app and media audio.
• Optionally send your iPhone or iPad microphone to a Mac app with the separately installed BlackHole 2ch driver.
• Connect up to two paired devices, with one device handling audio at a time.

PAIR ONCE, STAY IN CONTROL

Use a temporary code to pair a trusted device. Saved devices can reconnect while TailView Mac is running. Pause Access disconnects all viewers immediately; Revoke removes a device's permission. Optional widgets and lock-screen controls make returning to a session easier.

TRY FREE, UNLOCK ONCE

Start the 7-day Trial with a free in-app purchase. After seven days, remote viewing, control, and audio require the one-time Lifetime Unlock. Saved Macs and settings remain. The trial does not renew, there is no automatic charge, and there is nothing to cancel. Apple shows your local unlock price before purchase. Restore Purchases restores access for the purchasing Apple Account.

WHAT YOU NEED

• A Mac with macOS 14 or later, awake and signed in, running the free TailView Mac companion.
• Tailscale installed and connected on your Mac and mobile device, with network rules permitting the connection. Tailscale is a separate service with its own plans and terms.
• Screen Recording permission on the Mac; Accessibility permission for remote input.
• Microphone permission only if you choose microphone return.

TailView does not create a TailView account or run a hosted remote desktop. Screen, audio, and control travel through your Tailscale network, which may use direct or encrypted relay connections. Both TailView apps are open source under Apache 2.0.

Setup, the free Mac download, privacy, and support:
https://alexmorris10x.github.io/tailview/

## In-app purchases

| Reference | Product ID | Type | English display name | Price | Description |
| --- | --- | --- | --- | --- | --- |
| Seven-day trial | `com.10x.tailview.ios.trial7` | Non-consumable | `7-day Trial` | Free / Price Tier 0 | `7 days of screen, control, and audio. No auto-charge.` |
| Lifetime | `com.10x.tailview.ios.lifetime` | Non-consumable | `Lifetime Unlock` | US base price $9.99 | `Permanent remote access. One-time purchase.` |

Use Apple's permitted non-subscription trial model. Do not create an auto-renewable subscription, subscription introductory offer, server license key, or external checkout. The app must show trial duration, the functions that stop, and the local lifetime price before starting the trial. A restored trial keeps its original start date and does not restart. Configure availability and localizations for both products, attach their review screenshots, and include them with the first app submission.

Family Sharing is not advertised in this listing. If enabled in App Store Connect, update the copy and test the resulting StoreKit ownership behavior before claiming it.

## App privacy and permissions

The source currently sends session data between user-selected devices; it has no developer-operated collection endpoint, tracking SDK, ads, or analytics service. Its local diagnostics are not automatically uploaded. Use this as the basis for the App Privacy questionnaire, then answer the actual current questions against the exact release build. Apple-handled transactions, developer access to Apple diagnostics, and any future SDK must be accounted for accurately; do not blindly label every datum "not collected" because it stays off a TailView server.

Screen, microphone, clipboard, paired-device records, and local diagnostics are explained in the public privacy policy. The privacy manifest and required-reason API declarations must match the shipped source. No sensitive screen or customer material belongs in screenshots or review attachments.

## App Review notes (as submitted 7 November 2026)

Sign-in required: No. Contact: Alex Morris, the address in App Store Connect. The setup uses a reviewer-owned Mac; it gives no access to the developer's desktop or network.

```text
TailView is a remote desktop client for a Mac owned or administered by the user. It mirrors the Mac's whole desktop; it does not download or execute Mac applications. It requires macOS 14+ and Tailscale on both devices. There is no TailView account or developer-hosted desktop.

REVIEW SETUP — USE A MAC YOU CONTROL

1. Download the free, Developer ID-signed and notarized Mac companion: https://github.com/alexmorris10x/tailview/releases/tag/v1.0.0-mac . Open the DMG, drag TailView Mac into Applications, and launch it.
2. Install Tailscale on the Mac and review iPhone/iPad; connect both to your own Tailscale network. Permit the device to reach the Mac on TCP 47820 if your network has restrictive rules.
3. Grant TailView Mac Screen Recording permission, reopen it if macOS requests, and choose Start sharing. Keep the Mac awake and signed in. Open a harmless TextEdit document for the interaction test.
4. Choose Pair a new device on the Mac. In the iOS app, enter the Mac address and current code shown on the Mac, then choose Pair Mac. Codes are single-use and last five minutes; choose Pair a new device again for a fresh code. Pairing does not start the trial.
5. Choose Start 7-day free trial and confirm the zero-price "7-day Trial" item in Apple's review purchase environment. It is a non-consumable and never renews or charges. "Lifetime Unlock" is a separate $9.99 US one-time non-consumable. Restore Purchases restores the original entitlement without restarting an expired trial. Trial expiry stops remote viewing/control/audio while preserving saved Macs, setup, purchases and restore.
6. For keyboard/pointer control, enable remote-control consent in both apps and grant TailView Mac Accessibility permission. Type into the harmless document; viewing also works with control disabled.
7. Test Mac audio with a harmless audio file. Optional microphone return requires the separately installed BlackHole 2ch driver, iOS microphone permission, and Mac audio routing or manual input selection. BlackHole is not bundled or required for viewing, remote input or Mac-to-device audio.
8. Disconnect and reconnect using the saved Mac. Pause Access on the Mac disconnects viewers; Resume Access allows reconnection. Revoke removes a device's authorization and requires new pairing.

Both products are intended to accompany this first app submission. Background audio supports ongoing user-started remote audio sessions. Optional lock-screen controls manage those sessions. Mac-only display-management interfaces are not included in the iOS client.

Full setup: https://alexmorris10x.github.io/tailview/setup.html . Both client and host are Apache 2.0 open source. Please use the submission contact if the Mac or network prerequisites prevent review.
```

[Full setup instructions](https://alexmorris10x.github.io/tailview/setup.html). Never put real credentials, tailnet auth keys, or pairing secrets in this repository. A supporting recording does not replace functional review access.

## Submission — 7 November 2026

- First submission of iOS 1.0 (build `20261030110510`) with `com.10x.tailview.ios.trial7` (7-day Trial, $0 non-consumable) and `com.10x.tailview.ios.lifetime` (Lifetime Unlock, $9.99 US non-consumable).
- Submitted 7 November 2026 at 18:54 Taipei (10:54 UTC): [App Review submission](https://appstoreconnect.apple.com/apps/6828728093/distribution/reviewsubmissions/details/2f7fc97c-89c6-45f7-9b00-ed81a07b582b) `2f7fc97c-89c6-45f7-9b00-ed81a07b582b`, three items, all Waiting for Review.
- Same day: ASO listing change (en-US name, subtitle and keywords above, plus the new es-MX localization).
- Release type: automatic after approval.

Submission is not approval or public release.

## Pre-submission checklist (kept for history; submitted 7 November 2026)

1. Publish and open the marketing, privacy, and support URLs; replace the site's pending-download text only when each download is actually available.
2. Make the notarized Mac host downloadable with a source tag and SHA-256 checksum.
3. Configure both products and verify the release build's trial, expiry, purchase, and restore behavior in StoreKit testing and the available Apple test environment.
4. Supply real iPhone and iPad screenshots in the sizes App Store Connect currently requests, using an isolated demo desktop. Show connection/setup, remote view and controls, and the trial/unlock screen. Do not present the website illustration as an app screenshot.
5. Complete age-rating, export-compliance, content-rights, availability, contact, and privacy forms truthfully for this build; no guessed account answers.
6. Exercise the documented reviewer-owned Mac setup and attach the corrected build and first in-app purchases. Alex handles TestFlight/App Store submission and the release decision.

References: [App Review Guidelines 3.1.1 and 4.2.7](https://developer.apple.com/app-store/review/guidelines/), [Apple app privacy details](https://developer.apple.com/app-store/app-privacy-details/).

Screenshots and purchase-review images as uploaded: [screenshots/](screenshots/README.md) (moved from Google Drive on 1 Nov 2026).
