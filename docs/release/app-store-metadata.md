# TailView App Store metadata draft

**Status (2026-10-30):** Build `20261030110510`, required iPhone/iPad screenshots, and both purchase-review images are processed and attached. Version 1.0, the free trial, and lifetime unlock passed Add for Review validation and share one unsubmitted draft. Agreements are Active and release remains manual. Visible local StoreKit purchase, restore, and active-session expiry checks passed on the physical iPhone. Actual reinstall/restore, declined Ask to Buy retry, and full setup with the distributed Mac app remain unresolved; see [the remaining work](../TODO.md). No submission or approval is claimed.

## Listing

- **Name:** TailView – Remote Mac
- **Subtitle:** Your Mac over Tailscale
- **Primary category:** Utilities
- **Secondary category:** Productivity
- **Download price:** Free
- **iOS bundle identifier:** `com.10x.tailview.ios`
- **Minimum OS:** iOS / iPadOS 17
- **Marketing URL:** `https://alexmorris10x.github.io/tailview/`
- **Support URL:** `https://alexmorris10x.github.io/tailview/support.html`
- **Privacy policy URL:** `https://alexmorris10x.github.io/tailview/privacy.html`
- **Copyright:** 2026 Alex Morris
- **Keywords:** `remote,desktop,mac,tailscale,screen,keyboard,mouse,audio,control,ipad`

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

Family Sharing is not advertised in this launch draft. If enabled in App Store Connect, update the copy and test the resulting StoreKit ownership behavior before claiming it.

## App privacy and permissions

The source currently sends session data between user-selected devices; it has no developer-operated collection endpoint, tracking SDK, ads, or analytics service. Its local diagnostics are not automatically uploaded. Use this as the basis for the App Privacy questionnaire, then answer the actual current questions against the exact release build. Apple-handled transactions, developer access to Apple diagnostics, and any future SDK must be accounted for accurately; do not blindly label every datum "not collected" because it stays off a TailView server.

Screen, microphone, clipboard, paired-device records, and local diagnostics are explained in the public privacy policy. The privacy manifest and required-reason API declarations must match the shipped source. No sensitive screen or customer material belongs in screenshots or review attachments.

## App Review notes and saved setup

TailView is a general remote-desktop client for a Mac owned or administered by the user. It mirrors the whole Mac desktop; the host application and processing remain on that Mac. The iOS client does not download or execute Mac applications. The separate free Mac host is distributed directly with Developer ID signing and notarization.

Tailscale must be installed and connected on both devices. TailView has no separate account login. Pairing authorizes a device through a temporary code and then uses a saved credential. Screen Recording and Accessibility consent are granted locally on the Mac; microphone permission on iOS is optional.

The iOS app is free to download. `com.10x.tailview.ios.trial7` is a free non-consumable named "7-day Trial"; it starts an explicit seven-day trial. `com.10x.tailview.ios.lifetime` is a paid non-consumable lifetime unlock. These are not subscriptions. The trial does not charge automatically. When it expires, remote viewing, control, and audio stop, while saved settings, setup help, purchase, and restore remain available. Please use the App Review purchase environment to test both products.

Background audio is used for an ongoing user-started remote audio session, including microphone return if enabled. Lock-screen controls are optional session controls. The Mac companion includes advanced display-management controls; those Mac-only private system interfaces are not part of the iOS client.

The following reviewer-owned Mac setup was saved in App Store Connect on 2026-10-30. It does not provide access to the developer's desktop or network. The flow has not been independently exercised or accepted by App Review.

1. Use a Mac running macOS 14 or later. Download the free, Developer ID-signed and notarized companion from [the Mac release](https://github.com/alexmorris10x/tailview/releases/tag/v1.0.0-mac), open its DMG, drag TailView Mac into Applications, and launch it.
2. Install Tailscale on the Mac and review iPhone/iPad, and connect both to a network you control. Permit the review device to reach the Mac on TCP port 47820. There is no TailView login.
3. Allow Screen Recording, reopen TailView Mac if macOS requests it, and choose **Start sharing**. Keep the Mac awake and signed in. Open a harmless TextEdit document for the interaction test.
4. Choose **Pair a new device** on the Mac. Enter its displayed address and current code in the iOS app, then choose **Pair Mac**. Codes are single-use and expire after five minutes; generate another on the Mac when needed. Pairing does not start the trial.
5. Choose **Start 7-day free trial** and confirm the free **7-day Trial** item in Apple's review purchase environment. It never renews or charges automatically. **Lifetime Unlock** is a separate one-time non-consumable, with a US base price of $9.99. **Restore Purchases** preserves the original entitlement and does not restart an expired trial.
6. For keyboard and pointer control, enable remote-control consent in both apps and grant TailView Mac Accessibility permission. Type into the harmless document. Viewing works with control disabled.
7. Test Mac audio with a harmless audio file. Optional microphone return additionally requires BlackHole 2ch, iOS microphone consent, and the Mac app's audio-routing option or manual input selection; it is not needed for viewing, remote input, or Mac-to-device audio.
8. Disconnect and reconnect to the saved Mac. **Pause Access** disconnects all viewers, **Resume Access** permits saved-device connections, and **Revoke** requires fresh pairing.

[Full setup instructions](https://alexmorris10x.github.io/tailview/setup.html). If a prerequisite prevents review, use the contact listed in the submission. Never put real credentials, tailnet auth keys, or pairing secrets in this repository. A supporting recording does not replace functional review access.

## Before Alex submits

1. Publish and open the marketing, privacy, and support URLs; replace the site's pending-download text only when each download is actually available.
2. Make the notarized Mac host downloadable with a source tag and SHA-256 checksum.
3. Configure both products and verify the release build's trial, expiry, purchase, and restore behavior in StoreKit testing and the available Apple test environment.
4. Supply real iPhone and iPad screenshots in the sizes App Store Connect currently requests, using an isolated demo desktop. Show connection/setup, remote view and controls, and the trial/unlock screen. Do not present the website illustration as an app screenshot.
5. Complete age-rating, export-compliance, content-rights, availability, contact, and privacy forms truthfully for this build; no guessed account answers.
6. Exercise the documented reviewer-owned Mac setup and attach the corrected build and first in-app purchases. Alex handles TestFlight/App Store submission and the release decision.

References: [App Review Guidelines 3.1.1 and 4.2.7](https://developer.apple.com/app-store/review/guidelines/), [Apple app privacy details](https://developer.apple.com/app-store/app-privacy-details/).
