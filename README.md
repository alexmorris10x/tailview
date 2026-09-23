# TailView

An exploratory, private Mac-to-iPhone/iPad screen viewer with microphone return. The Mac app captures its main display using ScreenCaptureKit and sends JPEG frames directly to one authenticated viewer over the existing Tailscale network. The iOS app displays the frames and sends its microphone to the Mac. The Mac can expose that audio as an input through BlackHole 2ch.

This is a prototype. It does not yet provide remote keyboard/mouse control, Mac sound playback, reconnect, clipboard transfer, file transfer, H.264 compression, or a reviewed security release. Screen sharing is only active after pressing **Start sharing** on the Mac. The Mac listens on its Tailscale IPv4 address, with a fresh session code for each run. Normal viewing and microphone streaming do not record frames or audio to disk.

## Build

Run `xcodegen generate` in this folder, then open `TailView.xcodeproj` in Xcode. Build the **TailViewMac** app for the Mac and **TailViewIOS** for the iPhone or iPad. The project pins Alex's existing development team and separate bundle IDs; check signing in Xcode if installing on another account.

## Use

1. Connect the Mac and iPhone/iPad to Tailscale.
2. Open TailViewMac and press **Start sharing**. macOS will request Screen Recording permission. If you grant it, quit and reopen the app before trying again.
3. On the Mac, choose **Pair a new device**. In TailView on the iPhone or iPad, enter the Mac's Tailscale address, a profile name, and the current session code. Tap **Pair and connect**. Pairing is open for five minutes or until one device pairs.
4. On later sessions, press **Start sharing** on the Mac and tap its saved profile on the iPhone or iPad. The session code does not need to be entered again. Tap **Start microphone** when you want to send your voice, then allow microphone access when prompted.
5. To make the device microphone available to Mac apps, install [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole) (`brew install --cask blackhole-2ch`), reboot the Mac, and select **BlackHole 2ch** as the input in the Mac app that needs your voice.
6. Press **Stop sharing** on the Mac to end capture and close the connection.

The iOS viewer offers **Cancel connection** while connecting and times out after 10 seconds. A new Mac sharing session generates a new code, but saved profiles reconnect through a separate credential. **Connect once** still accepts the current code without pairing. You can remove a profile on the iOS device; to remove its access to the Mac, use **Revoke** in the Mac app's paired devices list. Revocation disconnects an active viewer. To pair it again, open a new pairing window on the Mac and use the current code.

If the iOS app cannot connect, check that macOS Firewall allows incoming connections for TailView Mac. The host still binds only to its Tailscale IPv4 address. Keep the Mac awake and signed in while sharing.

BlackHole installation requires the Mac administrator password and a restart. TailView does not install or change the audio driver itself. Video can be tested before BlackHole appears in macOS Audio Devices; the Mac app reports microphone routing as unavailable in that case.

Test the microphone on the physical iPhone or iPad. iPhone Mirroring can display the viewer, but macOS does not expose the mirrored iPhone's microphone to it. TailView selects the device's built-in microphone when available and displays its input peak. The Mac app reports the received audio level in dBFS, even if BlackHole is unavailable.

Debug builds have **Debug Settings** in the iOS toolbar. **Record-only microphone check** stops streaming, records four seconds with the live capture audio-session mode, reports meter and file peaks, then deletes the temporary audio. **Play speaker test tone** checks device playback only and requires the microphone to be off. **Send generated audio** bypasses the microphone and verifies only the network path and Mac receiver. These checks are distinct: a successful generated-audio or speaker test does not prove microphone capture.

For an isolated hardware check on a paired physical device, launch the debug iOS app with `--tailview-test-isolated-recorder`. This uses the system's record-only audio session without connecting to the Mac or playing a tone. It deletes the temporary audio and writes only the meter, file frame count, file size, duration, and route summary to `Documents/tailview-mic-diagnostic.txt` in TailView's app container. The diagnostic can be retrieved with `xcrun devicectl device copy from` using that device's exact identifier and TailView's app data container.

On the physical iPhone used during development, screen viewing worked and generated PCM reached the Mac at a nonzero level. After installing BlackHole and restarting the Mac, an independent recording of BlackHole's input measured iPhone-generated PCM at about -12 dBFS. The live microphone, recorder meter, and temporary recording file still reported silence (-90 dBFS). The iPhone audio route showed its built-in microphone and speaker with output volume at zero, so the on-device acoustic tone did not provide a reliable stimulus. Real microphone capture remains unverified.

On the physical iPad running iPadOS 27, the record-only diagnostic captured zero frames with its Device Hub screen view open and 192,000 frames (four seconds) at a -30 dBFS peak in a later run without that view. The original live capture used `.playAndRecord` with `.measurement` mode and sent silent samples even after its Device Hub view was closed. Changing live capture to the record-only `.default` mode and running without the iPad Device Hub screen view produced nonzero audio at the Mac (-18 dBFS peak in TailView). An independent FFmpeg capture from BlackHole 2ch measured a -7.3 dBFS peak. After TailView moved to the iPad background, BlackHole still captured nonzero audio (-32.4 dBFS peak in a second sample). This verifies microphone-to-Mac-app routing and background capture on that iPad. In this setup, close the iPad Device Hub screen view before using its microphone. Both the audio-session mode and Device Hub view affected the tests; do not infer that either alone explains every silent run.

## Transport and scope

TCP port 47820 is bound to the Mac's Tailscale IPv4 address only. A 36-character random session code is required for one-time viewing or for creating a saved pairing while the Mac has explicitly opened pairing. Saved profiles use a randomly generated 256-bit credential held in the iOS Keychain; the Mac Keychain holds a SHA-256 digest for validation. The session code itself is not saved. Mac screen capture still requires **Start sharing** for every session. Tailscale encrypts the transport; TailView does not add a second layer of encryption, so use it only on a tailnet whose members you trust. This removes Jump Desktop from the screen and microphone path, while Tailscale still supplies connectivity and may use its relay infrastructure.

The Mac app currently runs without App Sandbox because its Tailscale address lookup, screen capture, socket listener, and BlackHole output have only been validated in that configuration. Any tailnet peer with the current session code can connect while sharing is active; a device with a valid saved credential can connect whenever sharing is active. The prototype has no peer allowlist, repeated-attempt limit, or independent security review. Keep the GitHub repository private and use this build only on a trusted tailnet until those controls and a sandboxed build have been tested.

The initial implementation captures only the Mac's first display at up to 8 frames per second and a maximum width of 1280 pixels. JPEG favors implementation simplicity over bandwidth and responsiveness. The microphone uses 48 kHz, 16-bit, mono PCM. Packet type 1 is JPEG, type 2 is PCM; each packet has a one-byte type and a four-byte big-endian length.

Run `scripts/test-transport.sh` to test the connection protocol on loopback without Screen Recording permission or a virtual audio driver.
