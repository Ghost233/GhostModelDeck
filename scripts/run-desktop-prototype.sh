#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
flutter_sdk="${JEV_FLUTTER_SDK:-$HOME/flutter}"
cd "$task_root"
export PUB_CACHE="$task_root/.tooling/pub-cache"
export XDG_CONFIG_HOME="$task_root/.tooling/config"
export CI=true
if [[ ! -x "$flutter_sdk/bin/flutter" ]]; then
  echo "Flutter SDK is required at $flutter_sdk"
  exit 1
fi
"$flutter_sdk/bin/flutter" --suppress-analytics build macos --release --target lib/prototype_main.dart
open "$task_root/build/macos/Build/Products/Release/GhostModelDeck Prototype.app"
