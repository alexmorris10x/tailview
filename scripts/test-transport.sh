#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p DerivedData/Tests
swiftc Shared/Packet.swift Shared/PairingRequest.swift Shared/ControlCommand.swift MacHost/AudioSink.swift MacHost/VideoServer.swift Tests/TransportSmoke.swift -o DerivedData/Tests/TransportSmoke
DerivedData/Tests/TransportSmoke 127.0.0.1
swiftc Shared/ScreenViewport.swift Tests/ViewportSmoke.swift -o DerivedData/Tests/ViewportSmoke
DerivedData/Tests/ViewportSmoke
swiftc Shared/ControlCommand.swift IOSViewer/ModifierSelection.swift Tests/ModifierSmoke.swift -o DerivedData/Tests/ModifierSmoke
DerivedData/Tests/ModifierSmoke
swiftc -parse-as-library MacHost/DisplayControl/BacklightController.swift MacHost/DisplayControl/LocalInputController.swift Tests/DisplayControlSmoke.swift -o DerivedData/Tests/DisplayControlSmoke
DerivedData/Tests/DisplayControlSmoke
