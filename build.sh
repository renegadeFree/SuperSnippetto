#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
task_build_dir="${TMPDIR:-/tmp}/supersnippetto-build"
mkdir -p "$task_build_dir/module-cache" "SuperSnippetto.app/Contents/MacOS" "SuperSnippetto.app/Contents/Resources"
xcrun swiftc -swift-version 5 -O -module-cache-path "$task_build_dir/module-cache" \
  -target arm64-apple-macosx13.0 Source/*.swift \
  -o "SuperSnippetto.app/Contents/MacOS/SuperSnippetto"
cp Info.plist "SuperSnippetto.app/Contents/Info.plist"
cp Resources/SuperSnippetto.sdef "SuperSnippetto.app/Contents/Resources/SuperSnippetto.sdef"
cp Resources/AppIcon.icns "SuperSnippetto.app/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier it.local.SuperSnippetto "SuperSnippetto.app"
echo "Creata: $PWD/SuperSnippetto.app"
