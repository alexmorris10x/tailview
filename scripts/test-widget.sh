#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p DerivedData/Tests
swiftc -D DEBUG WidgetSupport/WidgetRoute.swift Tests/WidgetRouteSmoke.swift -o DerivedData/Tests/WidgetRouteDev
DerivedData/Tests/WidgetRouteDev
swiftc WidgetSupport/WidgetRoute.swift Tests/WidgetRouteSmoke.swift -o DerivedData/Tests/WidgetRouteRelease
DerivedData/Tests/WidgetRouteRelease
