#!/usr/bin/env bash

set -euo pipefail

developer_directory="$(xcode-select --print-path)"
if [[ ! -d "$developer_directory/Platforms/MacOSX.platform" ]]; then
    echo "Skipping local tests: full Xcode is not selected. GitHub Actions will run them for the pull request." >&2
    exit 0
fi

xcodebuild test \
    -project jungle.xcodeproj \
    -scheme jungle \
    -configuration Debug \
    -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO
