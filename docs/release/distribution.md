# Public distribution

The iOS app goes through the App Store; the free Mac host is a Developer ID-signed and notarized direct download. The public site is static, self-contained HTML under `docs/site/`. No paid hosting service, new domain, analytics dependency, or bundled driver is required.

## Mac package

`scripts/package-mac-release.sh` builds a universal Release archive using `~/bin/ios-dev-build`, signs nested code inside-out with hardened runtime and secure timestamps, checks for debug entitlements, notarizes and staples the app, and then creates, signs, notarizes, and staples a DMG. It runs signature, Gatekeeper, and disk-image checks before reporting the final DMG and SHA-256 file. It never uploads to GitHub or submits an app to the App Store.

Prerequisites on the Mac:

- Xcode, XcodeGen, Python 3, `~/bin/ios-dev-build`, and `~/bin/lane`.
- An installed **Developer ID Application** signing identity with its private key. Apple Development and Apple Distribution certificates do not substitute for it.
- An existing `notarytool` Keychain profile authorized for the developer team. Configure credentials outside the repo; do not pass a raw password or API private key into this script or place it in an environment file.

Use the exact installed identity and Keychain profile names:

```sh
export TAILVIEW_DEVELOPER_ID='Developer ID Application: Your Name (TEAMID)'
export TAILVIEW_NOTARY_PROFILE='tailview-notary'
./scripts/package-mac-release.sh --check
./scripts/package-mac-release.sh
```

`--check` only validates local prerequisites. It does not authenticate the notary profile, build, upload, or establish that notarization will succeed. A normal run checks Mac capacity and creates an isolated folder below `~/Developer/builds/agent-scratch/tailview-release/`. `TAILVIEW_RELEASE_ROOT` may choose another task folder under `~/Developer/builds`; synced folders and external disks are refused. No existing installed app is replaced. A failed signing/notary/Gatekeeper check is a failed public package, not a file to upload anyway.

The packaging script deliberately gives TailView no executable entitlements: the non-sandboxed Mac host currently needs none beyond user-granted privacy permissions. Revisit that assumption if adding XPC services, a sandbox, or helper code. The script strips any development provisioning profile only from its staging copy. It includes `LICENSE` and `NOTICE` beside the app in the disk image; Tailscale and BlackHole are not included.

After a successful package, create a release at the corresponding source commit in `alexmorris10x/tailview`, upload the DMG and checksum, and describe required OS versions, changes, and the matching iOS version. Publish only the final artifacts, not archives, notary logs, local profiles, or intermediate build folders. Install the downloaded release on a separate clean Mac account or test Mac when available to confirm first-run permission and pairing behavior; signing checks alone do not establish a successful first-run experience.

Use a stable Developer ID identity across Mac releases so privacy permissions can persist. Do not ship a development-signed app as the public Mac download or instruct customers to bypass Gatekeeper. Private display interfaces remain subject to OS compatibility even when notarization succeeds.

## Website

`.github/workflows/pages.yml` uses official GitHub Pages actions to publish only `docs/site/` to `https://alexmorris10x.github.io/tailview/`. It has no build dependency and includes a public-repository job guard. Keep Actions disabled while this repository is private. After the repository's public-source preparation is complete and it is made public, enable Actions and select **GitHub Actions** as the Pages source. Trigger the workflow manually once, or push a change under `docs/site/`.

All site assets are local and links are relative. The initial page deliberately says the Mac and App Store downloads are being prepared. Once each is actually published, replace that text and link to the real signed DMG or App Store record. Do not invent an App Store ID or imply the download is approved. Keep the trial terms and price in sync with the StoreKit products; the customer always sees Apple's localized purchase price before paying.

Production URLs expected by the app and App Store listing:

- `/` — product and download availability
- `/setup.html` — Tailscale, installation, consent, pairing, controls, uninstall
- `/support.html` — connection, audio, purchase, and restore help
- `/privacy.html` — session transport, local state, diagnostics, and third-party services

The Pages workflow does not publish the rest of `docs/`. GitHub repository visibility and source licensing are separate operations from publishing this website. The first release needs a functional reviewer demo using synthetic data and isolated network access; see [metadata and review notes](app-store-metadata.md).

## Source licensing

Original source and artwork are Apache 2.0. The [dependency inventory](dependencies.md) records system dependencies and the separately installed Tailscale/BlackHole components. Shipping the convenient signed iOS binary for a one-time purchase does not revoke the rights granted by the source license. People can build the source themselves, modify it, and redistribute subject to that license; do not describe source access as a security audit or a guarantee.

References: [Developer ID](https://developer.apple.com/developer-id/), [Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow), [GitHub Pages custom workflows](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages).
