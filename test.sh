#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
binary="$(mktemp /tmp/live-wallpaper-tests.XXXXXX)"
trap 'rm -f "$binary"' EXIT
xcrun swiftc -O Sources/Core.swift Tests/main.swift -o "$binary"
"$binary"
