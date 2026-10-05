#!/usr/bin/env bash
set -euo pipefail
export CI=true
export PUB_CACHE=/workspace/pub-cache
export FLUTTER_SUPPRESS_ANALYTICS=true
export PATH=/workspace/bin:/opt/flutter/bin:$PATH
mkdir -p /workspace/inbox
trap 'printf "%s\n" "$?" > /workspace/bootstrap.exit' EXIT
if [[ ! -d /opt/flutter/.git ]]; then
  apt-get update
  apt-get install -y --no-install-recommends curl git unzip xz-utils libglu1-mesa libgtk-3-0 fonts-noto-cjk ca-certificates
  git clone --depth 1 --branch 3.47.6 https://github.com/flutter/flutter.git /opt/flutter
fi
[[ "$(git -C /opt/flutter rev-parse HEAD)" == 5fc346839b5d0eef006ed8404392afb4dfae428d ]]
mkdir -p /workspace/bin
# The cached app-JIT CLI snapshot crashes on this arm64 container runtime.
# Execute the identical pinned tool sources while retaining the standard CLI.
cat > /workspace/bin/flutter <<'CLI'
#!/usr/bin/env bash
exec /opt/flutter/bin/cache/dart-sdk/bin/dart --disable-dart-dev \
  --packages=/opt/flutter/packages/flutter_tools/.dart_tool/package_config.json \
  /opt/flutter/packages/flutter_tools/bin/flutter_tools.dart "$@"
CLI
chmod +x /workspace/bin/flutter
flutter --suppress-analytics --version
flutter --suppress-analytics precache --linux
printf 'ready\n' > /workspace/ready
trap - EXIT
while true; do
  if [[ -f /workspace/inbox/job.sh ]]; then
    mv /workspace/inbox/job.sh /workspace/job.sh
    set +e
    bash /workspace/job.sh > /workspace/job.log 2>&1
    job_exit=$?
    set -e
    printf '%s\n' "$job_exit" > /workspace/job.exit
  fi
  sleep 1
done
