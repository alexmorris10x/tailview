#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p DerivedData/Tests
swiftc Shared/AudioJitterBuffer.swift Shared/AudioConnectionGate.swift Shared/ReconnectBackoff.swift Shared/AuthenticationReply.swift Tests/AudioReliabilitySmoke.swift -o DerivedData/Tests/AudioReliabilitySmoke
DerivedData/Tests/AudioReliabilitySmoke
swiftc Shared/Packet.swift Shared/PairingRequest.swift Shared/ControlCommand.swift Shared/AudioJitterBuffer.swift MacHost/AudioSink.swift MacHost/VideoServer.swift Tests/TransportSmoke.swift -o DerivedData/Tests/TransportSmoke
DerivedData/Tests/TransportSmoke 127.0.0.1
swiftc Shared/ScreenViewport.swift Tests/ViewportSmoke.swift -o DerivedData/Tests/ViewportSmoke
DerivedData/Tests/ViewportSmoke
swiftc Shared/ControlCommand.swift IOSViewer/ModifierSelection.swift MacHost/FunctionKeys.swift Tests/ModifierSmoke.swift -o DerivedData/Tests/ModifierSmoke
DerivedData/Tests/ModifierSmoke
swiftc -parse-as-library MacHost/DisplayControl/BacklightController.swift MacHost/DisplayControl/LocalInputController.swift Tests/DisplayControlSmoke.swift -o DerivedData/Tests/DisplayControlSmoke
DerivedData/Tests/DisplayControlSmoke
swiftc -parse-as-library MacHost/AudioRoutingController.swift Tests/AudioRoutingSmoke.swift -o DerivedData/Tests/AudioRoutingSmoke
DerivedData/Tests/AudioRoutingSmoke
