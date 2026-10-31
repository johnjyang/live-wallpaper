#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
binary="$(mktemp /tmp/live-wallpaper-playback.XXXXXX)"
trap 'rm -f "$binary"' EXIT
xcrun swiftc -swift-version 5 -D PLAYBACK_TEST -O Sources/Core.swift Sources/App.swift Tests/Playback.swift -framework AppKit -framework AVFoundation -o "$binary"
"$binary"
