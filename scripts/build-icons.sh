#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
resources_dir="$1"
icon_stage="$(mktemp -d "${TMPDIR:-/tmp}/deskloom-icons.XXXXXX")"
trap 'rm -rf "$icon_stage"' EXIT
for icon_name in C D; do
  icon_source="$project_dir/assets/icons/Icon$icon_name.png"
  iconset_dir="$icon_stage/Icon$icon_name.iconset"
  mkdir -p "$iconset_dir"
  cp -X "$icon_source" "$resources_dir/Icon$icon_name.png"
  for icon_size in 16 32 128 256 512; do
    /usr/bin/sips -z "$icon_size" "$icon_size" "$icon_source" --out "$iconset_dir/icon_${icon_size}x${icon_size}.png" >/dev/null
    retina_size=$((icon_size * 2))
    /usr/bin/sips -z "$retina_size" "$retina_size" "$icon_source" --out "$iconset_dir/icon_${icon_size}x${icon_size}@2x.png" >/dev/null
  done
  /usr/bin/iconutil --convert icns "$iconset_dir" --output "$resources_dir/DeskLoomIcon$icon_name.icns"
done
