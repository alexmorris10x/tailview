# TailView launch work

Updated 2026-10-30. These are the remaining release gates; completed work belongs in the specification or commit history.

- [ ] Alex must accept the updated Apple Developer Program agreement. App record `6828728093`, free base-app pricing, trial/lifetime prices, and 175-territory availability are configured.
- [ ] Verify the complete StoreKit flow in a working Apple test environment: explicit trial, original expiry after restore/reinstall, permanent purchase, cancellation/pending approval, revoked/refunded access, and active-session cutoff. Pure rule tests passed and simulator compilation passed; runtime tests failed system sandbox initialization. Do not repeat that simulator attempt without an environment change.
- [ ] Validate first launch and permission onboarding from the distributed Mac app. The public Apache 2.0 source and signed, notarized [Mac 1.0 download](https://github.com/alexmorris10x/tailview/releases/tag/v1.0.0-mac) are published. The previous host is actively connected; replace it at an idle boundary.
- [ ] Complete a fresh customer-style setup on a separate Mac account or test Mac and iPhone/iPad: Tailscale, pairing before trial, screen/control consent, optional microphone and routing, pause/revoke, reconnect, and purchase/restore. Keep this separate from build success.
- [ ] Capture real iPhone/iPad screenshots and prepare isolated App Review access with synthetic data, reachable Mac, and a way to obtain a fresh pairing code. An expired code or recording alone is insufficient.
- [ ] Finalize privacy/age-rating/export-compliance metadata, attach the release build and both in-app purchases, and provide the review notes. Alex handles TestFlight/App Store submission and the public release decision; neither has occurred yet.
