#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="/Applications/DeskLoom.app"
if [[ ! -x "$app_dir/Contents/MacOS/DeskLoom" ]]; then
  bash "$project_dir/scripts/build-native.sh"
fi
open "$app_dir"
