#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
task_icon_dir="$(mktemp -d "${TMPDIR:-/tmp}/supersnippetto-icon.XXXXXX")"
trap 'rm -rf "$task_icon_dir"' EXIT
mkdir -p "$task_icon_dir/AppIcon.iconset"
for task_icon_size in 16 32 128 256 512; do
    sips -z "$task_icon_size" "$task_icon_size" Resources/AppIcon.png --out "$task_icon_dir/AppIcon.iconset/icon_${task_icon_size}x${task_icon_size}.png" >/dev/null
    task_icon_retina=$((task_icon_size * 2))
    sips -z "$task_icon_retina" "$task_icon_retina" Resources/AppIcon.png --out "$task_icon_dir/AppIcon.iconset/icon_${task_icon_size}x${task_icon_size}@2x.png" >/dev/null
done
iconutil -c icns "$task_icon_dir/AppIcon.iconset" -o Resources/AppIcon.icns
