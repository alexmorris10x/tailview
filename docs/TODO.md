# TailView launch work

Updated 2026-10-30. These are the remaining release gates; completed work belongs in the specification or commit history.

- [ ] Finish Apple product availability/pricing and any required agreements in App Store Connect record `6828728093`. Keep the trial free and the permanent unlock at the agreed $9.99 US base price. Alex must accept agreements that require the account holder.
- [ ] Verify the complete StoreKit flow in a working Apple test environment: explicit trial, original expiry after restore/reinstall, permanent purchase, cancellation/pending approval, revoked/refunded access, and active-session cutoff. Pure rule tests passed and simulator compilation passed; runtime tests failed system sandbox initialization. Do not repeat that simulator attempt without an environment change.
- [ ] Finish the Developer ID-signed, notarized Mac download and public source/site publication; replace pending download copy only with usable artifacts. Validate first launch and permission onboarding from the distributed app.
- [ ] Complete a fresh customer-style setup on a separate Mac account or test Mac and iPhone/iPad: Tailscale, pairing before trial, screen/control consent, optional microphone and routing, pause/revoke, reconnect, and purchase/restore. Keep this separate from build success.
- [ ] Capture real iPhone/iPad screenshots and prepare isolated App Review access with synthetic data, reachable Mac, and a way to obtain a fresh pairing code. An expired code or recording alone is insufficient.
- [ ] Finalize privacy/age-rating/export-compliance metadata, attach the release build and both in-app purchases, and provide the review notes. Alex handles TestFlight/App Store submission and the public release decision; neither has occurred yet.
