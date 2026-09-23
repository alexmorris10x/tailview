#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p DerivedData/Tests
swiftc Shared/Packet.swift Shared/PairingRequest.swift MacHost/AudioSink.swift MacHost/VideoServer.swift Tests/TransportSmoke.swift -o DerivedData/Tests/TransportSmoke
DerivedData/Tests/TransportSmoke 127.0.0.1
