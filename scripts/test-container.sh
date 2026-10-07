#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
container_name="${GMD_TEST_CONTAINER:-ghostmodeldeck-flutter-dev}"

# The bootstrap consumes final names, so publish only verified uploads.
upload_verified() {
  local source_file="$1" destination="$2" upload_path="$2.upload"
  local expected_sha actual_sha
  expected_sha="$(shasum -a 256 "$source_file" | awk '{print $1}')" || return $?
  docker cp "$source_file" "${container_name}:${upload_path}" || return $?
  actual_sha="$(docker exec "$container_name" sha256sum "$upload_path" | awk '{print $1}')" || return $?
  if [[ "$expected_sha" != "$actual_sha" ]]; then
    echo "Upload verification failed: $destination" >&2
    if ! docker exec "$container_name" rm -f "$upload_path"; then
      echo "Upload cleanup failed: $upload_path" >&2
    fi
    return 1
  fi
  docker exec "$container_name" mv "$upload_path" "$destination" || return $?
}
[[ "$(docker context show)" == socktainer ]]
if ! docker inspect "$container_name" >/dev/null 2>&1; then
  docker image inspect node:22-bookworm >/dev/null
  docker run -d --name "$container_name" --network default --dns 119.29.29.29 --memory 4g \
    --entrypoint /bin/bash node:22-bookworm -c \
    'mkdir -p /workspace/inbox; while [ ! -f /workspace/inbox/bootstrap.sh ]; do sleep 1; done; exec bash /workspace/inbox/bootstrap.sh'
  if upload_verified scripts/container/bootstrap-flutter.sh /workspace/inbox/bootstrap.sh; then
    :
  else
    bootstrap_exit=$?
    if docker rm -f "$container_name"; then
      :
    else
      cleanup_exit=$?
      echo "Bootstrap container cleanup failed: $container_name (exit $cleanup_exit)" >&2
    fi
    exit "$bootstrap_exit"
  fi
fi
if [[ "$(docker inspect "$container_name" --format '{{.State.Running}}')" != true ]]; then
  docker logs --tail 30 "$container_name"
  echo 'Container stopped; inspect its failure before restarting.' >&2
  exit 1
fi
until docker exec "$container_name" test -f /workspace/ready; do
  sleep 5
  if [[ "$(docker inspect "$container_name" --format '{{.State.Running}}')" != true ]]; then
    docker logs --tail 30 "$container_name"
    exit 1
  fi
done
mkdir -p .tooling/container-tests
run_dir="$(mktemp -d "$task_root/.tooling/container-tests/run-XXXXXX")"
if [[ $# == 0 ]]; then set -- test; fi
COPYFILE_DISABLE=1 tar --no-xattrs -czf "$run_dir/source.tar.gz" pubspec.yaml pubspec.lock analysis_options.yaml lib test benchmarks
upload_verified "$run_dir/source.tar.gz" /workspace/inbox/source.tar.gz
cat > "$run_dir/job.sh" <<'JOB'
#!/usr/bin/env bash
set -euo pipefail
rm -rf /workspace/project
mkdir -p /workspace/project
cd /workspace/project
tar -xzf /workspace/inbox/source.tar.gz
flutter --suppress-analytics pub get
JOB
if [[ "$1" == format ]]; then
  printf '%q ' dart "$@" >> "$run_dir/job.sh"
else
  printf '%q ' flutter --suppress-analytics "$@" >> "$run_dir/job.sh"
fi
printf '\n' >> "$run_dir/job.sh"
docker exec "$container_name" rm -f /workspace/job.exit
upload_verified "$run_dir/job.sh" /workspace/inbox/job.sh
until docker exec "$container_name" test -f /workspace/job.exit; do
  if [[ "$(docker inspect "$container_name" --format '{{.State.Running}}')" != true ]]; then
    docker logs --tail 30 "$container_name"
    echo 'Test container stopped before the check job completed.' >&2
    exit 1
  fi
  sleep 5
done
docker exec "$container_name" base64 -w 0 /workspace/job.log | /usr/bin/base64 -D > "$run_dir/result.log"
remote_sha="$(docker exec "$container_name" sha256sum /workspace/job.log | awk '{print $1}')"
local_sha="$(shasum -a 256 "$run_dir/result.log" | awk '{print $1}')"
[[ "$local_sha" == "$remote_sha" ]]
docker exec "$container_name" base64 -w 0 /workspace/job.exit | /usr/bin/base64 -D > "$run_dir/exit"
cat "$run_dir/result.log"
echo "Evidence: $run_dir"
exit "$(cat "$run_dir/exit")"
