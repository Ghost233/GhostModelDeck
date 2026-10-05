#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
flutter_sdk="${JEV_FLUTTER_SDK:-$HOME/flutter}"
cd "$task_root"
jev_app_binary="$task_root/build/macos/Build/Products/Release/GhostModelDeck.app/Contents/MacOS/GhostModelDeck"
jev_running_commands="$(/bin/ps -axo comm=)"
if /usr/bin/grep -Fxq "$jev_app_binary" <<< "$jev_running_commands"; then
  echo '请先通过 Cmd+Q 退出 GhostModelDeck，再重新构建。' >&2
  exit 1
fi
export PUB_CACHE="$task_root/.tooling/pub-cache"
export XDG_CONFIG_HOME="$task_root/.tooling/config"
export CI=true
"$flutter_sdk/bin/flutter" --suppress-analytics build macos --release --target lib/main.dart
open "$task_root/build/macos/Build/Products/Release/GhostModelDeck.app"
