# TailView

An exploratory, private Mac-to-iPhone/iPad screen viewer with microphone return. The Mac app captures its main display using ScreenCaptureKit and sends JPEG frames directly to one authenticated viewer over the existing Tailscale network. The iOS app displays the frames and sends its microphone to the Mac. The Mac can expose that audio as an input through BlackHole 2ch.

This is a prototype. It does not yet provide remote keyboard/mouse control, Mac sound playback, reconnect, clipboard transfer, file transfer, H.264 compression, or a reviewed security release. Screen sharing is only active after pressing **Start sharing** on the Mac. The Mac listens on its Tailscale IPv4 address, with a fresh session code for each run. Normal viewing and microphone streaming do not record frames or audio to disk.

## Build

Run `xcodegen generate` in this folder, then open `TailView.xcodeproj` in Xcode. Build the **TailViewMac** app for the Mac and **TailViewIOS** for the iPhone or iPad. The project pins Alex's existing development team and separate bundle IDs; check signing in Xcode if installing on another account.

## Use

1. Connect the Mac and iPhone/iPad to Tailscale.
2. Open TailViewMac and press **Start sharing**. macOS will request Screen Recording permission. If you grant it, quit and reopen the app before trying again.
3. Enter the Mac's displayed address and session code into TailViewIOS and tap **Connect**. Tap **Start microphone** when you want to send your voice, then allow microphone access when prompted.
4. To make the device microphone available to Mac apps, install [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole) (`brew install --cask blackhole-2ch`), reboot the Mac, and select **BlackHole 2ch** as the input in the Mac app that needs your voice.
5. Press **Stop sharing** on the Mac to end capture and close the connection.

The iOS viewer offers **Cancel connection** while connecting and times out after 10 seconds. A new Mac sharing session generates a new code; reconnect with the newly displayed code.

If the iOS app cannot connect, check that macOS Firewall allows incoming connections for TailView Mac. The host still binds only to its Tailscale IPv4 address. Keep the Mac awake and signed in while sharing.

BlackHole installation requires the Mac administrator password and a restart. TailView does not install or change the audio driver itself. Video can be tested before BlackHole appears in macOS Audio Devices; the Mac app reports microphone routing as unavailable in that case.

Test the microphone on the physical iPhone or iPad. iPhone Mirroring can display the viewer, but macOS does not expose the mirrored iPhone's microphone to it. TailView selects the device's built-in microphone when available and displays its input peak. The Mac app reports the received audio level in dBFS, even if BlackHole is unavailable.

Debug builds have **Debug Settings** in the iOS toolbar. **Play test tone** plays through the device speaker while the microphone is streaming; a nonzero input peak is needed to prove acoustic capture. **Compare with system recorder** records a short temporary audio file, reports both meter and file peaks, then deletes the file. **Send generated audio** bypasses the microphone and verifies only the network path and Mac receiver. These are separate checks: a successful generated-audio test does not prove microphone capture.

On the physical iPhone used during development, screen viewing worked and generated PCM reached the Mac at a nonzero level. The live microphone and recorder diagnostics reported silence. The iPhone audio route showed its built-in microphone and speaker with output volume at zero. The cause of the silent input is still unresolved. BlackHole's package and receipt were installed, but macOS did not expose the device before a restart, so selectable Mac microphone routing has not been validated.

## Transport and scope

TCP port 47820 is bound to the Mac's Tailscale IPv4 address only. A 36-character random session code is required before any frame is sent. Tailscale encrypts the transport; TailView does not add a second layer of encryption, so use it only on a tailnet whose members you trust. This removes Jump Desktop from the screen and microphone path, while Tailscale still supplies connectivity and may use its relay infrastructure.

The initial implementation captures only the Mac's first display at up to 8 frames per second and a maximum width of 1280 pixels. JPEG favors implementation simplicity over bandwidth and responsiveness. The microphone uses 48 kHz, 16-bit, mono PCM. Packet type 1 is JPEG, type 2 is PCM; each packet has a one-byte type and a four-byte big-endian length.

Run `scripts/test-transport.sh` to test the connection protocol on loopback without Screen Recording permission or a virtual audio driver.
