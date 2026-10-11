#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
container_name="${GMD_TEST_CONTAINER:-ghostmodeldeck-flutter-dev}"
container system status >/dev/null

container_state() {
  container inspect "$container_name" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["status"]["state"])'
}

upload_verified() {
  local source_file="$1" destination="$2"
  local expected_sha actual_sha
  expected_sha="$(shasum -a 256 "$source_file" | awk '{print $1}')"
  container copy "$source_file" "${container_name}:${destination}"
  actual_sha="$(container exec "$container_name" sha256sum "$destination" | awk '{print $1}')"
  if [[ "$expected_sha" != "$actual_sha" ]]; then
    echo "Upload verification failed: $destination" >&2
    return 1
  fi
}

if ! container inspect "$container_name" >/dev/null 2>&1; then
  # Persistent state only uses a directory explicitly supplied by the operator.
  test_workspace="${GMD_TEST_WORKSPACE:?Set GMD_TEST_WORKSPACE to an existing absolute bind directory for a new test container}"
  [[ "$test_workspace" == /* && -d "$test_workspace" ]]
  container run -d --name "$container_name" --platform linux/arm64 --memory 4g \
    --volume "${test_workspace}:/workspace" --entrypoint /bin/bash node:22-bookworm -c \
    'mkdir -p /workspace/inbox; while [ ! -f /workspace/inbox/bootstrap.sh ]; do sleep 1; done; exec bash /workspace/inbox/bootstrap.sh'
  upload_verified scripts/container/bootstrap-flutter.sh /workspace/inbox/bootstrap.sh
fi
if [[ "$(container_state)" != running ]]; then
  container logs "$container_name"
  echo 'Container stopped; inspect its failure before restarting.' >&2
  exit 1
fi
until container exec "$container_name" test -f /workspace/ready; do
  sleep 5
  [[ "$(container_state)" == running ]] || exit 1
done
mkdir -p .tooling/container-tests
# One dependency cache owner per repository; jobs have separate source trees.
lock_dir="$task_root/.tooling/container-tests/.lock"
if ! mkdir "$lock_dir" 2>/dev/null; then
  echo "Another check owns $lock_dir; inspect its PID before retrying." >&2
  exit 1
fi
printf '%s\n' "$$" > "$lock_dir/pid"
release_lock() {
  local check_exit=$?
  rm -f "$lock_dir/pid"
  rmdir "$lock_dir" || echo "Check lock cleanup failed: $lock_dir" >&2
  exit "$check_exit"
}
trap release_lock EXIT
run_dir="$(mktemp -d "$task_root/.tooling/container-tests/run-XXXXXX")"
remote_dir="/workspace/checks/$(basename "$run_dir")"
if [[ $# == 0 ]]; then set -- test; fi
COPYFILE_DISABLE=1 tar --no-xattrs -czf "$run_dir/source.tar.gz" pubspec.yaml pubspec.lock analysis_options.yaml lib test benchmarks
container exec "$container_name" mkdir -p "$remote_dir/project"
upload_verified "$run_dir/source.tar.gz" "$remote_dir/source.tar.gz"
cat > "$run_dir/job.sh" <<'JOB'
#!/usr/bin/env bash
set -euo pipefail
export CI=true
export PUB_CACHE=/workspace/pub-cache
export FLUTTER_SUPPRESS_ANALYTICS=true
export PATH=/workspace/bin:/opt/flutter/bin:$PATH
cd "$(dirname "$0")/project"
tar -xzf ../source.tar.gz
flutter --suppress-analytics pub get
JOB
if [[ "$1" == format ]]; then
  printf '%q ' dart "$@" >> "$run_dir/job.sh"
else
  printf '%q ' flutter --suppress-analytics "$@" >> "$run_dir/job.sh"
fi
printf '\n' >> "$run_dir/job.sh"
upload_verified "$run_dir/job.sh" "$remote_dir/job.sh"
git rev-parse HEAD > "$run_dir/source-head"
shasum -a 256 "$run_dir/source.tar.gz" > "$run_dir/source.sha256"
printf '%s\n' "$container_name" > "$run_dir/container"
if container exec "$container_name" bash "$remote_dir/job.sh" > "$run_dir/result.log" 2>&1; then
  check_exit=0
else
  check_exit=$?
fi
printf '%s\n' "$check_exit" > "$run_dir/exit"
cat "$run_dir/result.log"
echo "Evidence: $run_dir"
exit "$check_exit"
