#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$project_dir"
mkdir -p build/cli
xcrun swiftc cli/ControlClient.swift -o build/cli/simvirtual-control
xcrun swiftc cli/AppleDirections.swift -framework MapKit -framework CoreLocation -o build/cli/apple-directions
xcodebuild -project SimVirtualLocation.xcodeproj -scheme SimVirtualLocation \
  -configuration Debug -derivedDataPath ./build -jobs 2 \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
