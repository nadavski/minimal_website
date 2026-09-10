#!/usr/bin/env bash
# Nocturne deployment. All cleanup is restricted to this application's resources.
# Installer revision 20260910-r4 (compatible with the existing r3 prod.tar.gz).
set -Eeuo pipefail
APP=nocturne-atelier
LABEL=io.nocturne.application
PAYLOAD_SHA256=e1b3472ade667fa24f27c12cdb65d4552e2708b93c2b7fe006dad4d048f4e2a2
release_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
port="${PORT:-8080}"
bind="${BIND_ADDRESS:-127.0.0.1}"
if (( EUID != 0 )); then
  command -v sudo >/dev/null || { echo 'Run this script as root (sudo is missing).' >&2; exit 1; }
  exec sudo env PORT="$port" BIND_ADDRESS="$bind" bash "$release_dir/deploy.sh" "$@"
fi
[[ $# == 0 ]] || { echo 'Usage: ./deploy.sh (optional PORT and BIND_ADDRESS environment variables)' >&2; exit 1; }
[[ "$port" =~ ^[1-9][0-9]{3,4}$ ]] && (( port >= 1024 && port <= 65535 )) || { echo 'PORT must be 1024–65535' >&2; exit 1; }
[[ "$bind" == 127.0.0.1 || "$bind" == 0.0.0.0 ]] || { echo 'BIND_ADDRESS must be 127.0.0.1 or 0.0.0.0' >&2; exit 1; }
[[ -f /etc/debian_version ]] || { echo 'This installer requires a Debian-family distribution.' >&2; exit 1; }
command -v apt-get >/dev/null || { echo 'apt-get is required.' >&2; exit 1; }
[[ -f "$release_dir/prod.tar.gz" ]] || { echo 'prod.tar.gz must be beside deploy.sh' >&2; exit 1; }
printf '%s  %s\n' "$PAYLOAD_SHA256" "$release_dir/prod.tar.gz" | sha256sum -c -

# Install only missing requirements from the host's configured repositories.
packages=()
command -v curl >/dev/null || packages+=(curl ca-certificates)
if ! command -v docker >/dev/null; then
  apt-get update
  packages+=(docker.io ca-certificates)
  # New Debian releases split the CLI out of docker.io; older ones bundle it.
  if apt-cache show docker-cli >/dev/null 2>&1; then packages+=(docker-cli); fi
elif ((${#packages[@]})); then apt-get update
fi
if ((${#packages[@]})); then
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"
fi
if ! docker info >/dev/null 2>&1; then
  if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null; then
    systemctl enable --now docker
  elif command -v service >/dev/null; then
    service docker start
  fi
fi
docker info >/dev/null || { echo 'Docker cannot start. A Docker-capable host/kernel is required.' >&2; exit 1; }

stage="$(mktemp -d -t nocturne-deploy.XXXXXXXX)"
candidate="${APP}-candidate-$$"
image="${APP}:$(date -u +%Y%m%dT%H%M%SZ)-$$"
old_ids=()
old_running=()
old_renamed=''
final_created=0
committed=0
phase=extract
diagnostics() {
  local log_file="$release_dir/deploy-failure-$(date -u +%Y%m%dT%H%M%SZ)-$$.log" name
  (umask 077
    {
      printf 'PHASE=%s\n' "$phase"
      if [[ -s "$stage/curl-error" ]]; then cat "$stage/curl-error"; fi
      for name in "$candidate" "$APP"; do
        [[ "$name" != "$APP" || "$final_created" == 1 ]] || continue
        if docker container inspect "$name" >/dev/null 2>&1; then
          printf '\nCONTAINER=%s\n' "$name"
          docker inspect --format 'Status={{.State.Status}} ExitCode={{.State.ExitCode}} OOMKilled={{.State.OOMKilled}} RestartCount={{.RestartCount}} Error={{.State.Error}}' "$name" || true
          docker port "$name" || true
          docker logs --tail 80 "$name" 2>&1 || true
        fi
      done
    } > "$log_file"
  )
  cat "$log_file" >&2
  printf 'DIAGNOSTICS=%s\n' "$log_file" >&2
}
cleanup() {
  status=$?
  trap - EXIT
  if (( ! committed )); then
    (( status == 0 )) || diagnostics || true
    local rollback_failed=0
    if (( final_created )); then
      if docker container inspect "$APP" >/dev/null 2>&1; then docker rm -f "$APP" >/dev/null 2>&1 || rollback_failed=1; fi
    fi
    if [[ -n "$old_renamed" ]]; then docker rename "$old_renamed" "$APP" || rollback_failed=1; fi
    for id in "${old_running[@]}"; do
      if ! docker start "$id" >/dev/null; then rollback_failed=1
      elif [[ "$(docker inspect --format '{{.State.Running}}' "$id" 2>/dev/null)" != true ]]; then rollback_failed=1; fi
    done
    if (( status != 0 )); then
      echo "DEPLOY=FAIL PHASE=$phase" >&2
      if (( rollback_failed )); then echo 'ROLLBACK=FAIL. Check the Docker errors above.' >&2
      elif ((${#old_running[@]})); then echo 'ROLLBACK=PASS. Previous containers are running again.' >&2
      else echo 'PREVIOUS=UNCHANGED. No previously running container was stopped.' >&2; fi
    fi
  fi
  docker rm -f "$candidate" >/dev/null 2>&1 || true
  if (( ! committed )); then docker image rm "$image" >/dev/null 2>&1 || true; fi
  case "$stage" in /tmp/nocturne-deploy.*) rm -rf --one-file-system -- "$stage" ;; esac
  exit "$status"
}
trap cleanup EXIT

# This exact, checksum-verified archive contains only the app and build inputs.
tar --no-same-owner --no-same-permissions -xzf "$release_dir/prod.tar.gz" -C "$stage"
(cd "$stage" && sha256sum -c SHA256SUMS)
release="$(tr -d '\r\n' < "$stage/dist/release.txt")"
phase=build
docker build --pull --label "$LABEL=$APP" --tag "$image" "$stage"
runtime=(--read-only --user 101:101 --cap-drop ALL --security-opt no-new-privileges:true
  --tmpfs /tmp:rw,nosuid,nodev,noexec,size=16m,mode=1777
  --tmpfs /var/cache/nginx:rw,nosuid,nodev,noexec,size=16m,uid=101,gid=101
  --pids-limit 100 --log-opt max-size=5m --log-opt max-file=2 --label "$LABEL=$APP")
phase=nginx-configuration
docker run --rm "${runtime[@]}" --network none "$image" nginx -t
phase=candidate-start
docker run -d "${runtime[@]}" --name "$candidate" -p 127.0.0.1::8080 "$image" >/dev/null
candidate_port="$(docker port "$candidate" 8080/tcp)"
candidate_port="${candidate_port##*:}"

request_get() {
  local url="$1" output="$2" container="$3" wait_seconds="$4" rc deadline
  deadline=$((SECONDS + wait_seconds))
  while :; do
    if [[ "$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null)" != true ]]; then
      echo "CONTAINER=NOT_RUNNING $container" >&2; return 1
    fi
    # Fresh, local GET on each attempt. Works without newer curl retry flags.
    if curl --disable --noproxy '*' --fail --silent --show-error --connect-timeout 1 --max-time 3 "$url" -o "$output" 2>"$stage/curl-error"; then
      return 0
    else rc=$?; fi
    # Retry transient connect/receive failures; do not hide HTTP/path errors.
    case "$rc" in 7|18|28|52|55|56) ;; *) cat "$stage/curl-error" >&2; return "$rc" ;; esac
    if (( SECONDS >= deadline )); then
      cat "$stage/curl-error" >&2
      printf 'HTTP=TIMEOUT after %ss waiting for %s\n' "$wait_seconds" "$url" >&2
      return "$rc"
    fi
    sleep 1
  done
}
verify() {
  local base="$1" container="$2" file path
  echo "VERIFY=WAITING PHASE=$phase (up to 45 seconds)"
  request_get "$base/healthz" "$stage/response" "$container" 45 || return $?
  [[ "$(<"$stage/response")" == ok ]] || { echo 'HEALTH=FAIL (unexpected response)' >&2; return 1; }
  for file in index.html styles.css app.js assets/atelier.webp assets/dial.webp assets/movement.webp release.txt; do
    path="$file"; [[ "$file" != index.html ]] || path=''
    request_get "$base/$path?v=$release" "$stage/response" "$container" 10 || return $?
    cmp -s "$stage/dist/$file" "$stage/response" || { echo "ASSET=FAIL $file" >&2; return 1; }
  done
  echo 'ASSETS=PASS (HTML, CSS, JavaScript and all three images)'
}
phase=candidate-health
verify "http://127.0.0.1:$candidate_port" "$candidate"

# Collect this installer's containers plus the two earlier Compose project names.
while IFS= read -r id; do [[ -z "$id" ]] || old_ids+=("$id"); done < <(
  {
    docker ps -aq --filter "label=$LABEL=$APP"
    docker ps -aq --filter label=com.docker.compose.project=nocturne-atelier --filter label=com.docker.compose.service=web
    docker ps -aq --filter label=com.docker.compose.project=atelier-nocturne --filter label=com.docker.compose.service=web
  } | sort -u
)
candidate_id="$(docker inspect --format '{{.Id}}' "$candidate")"
owned_ids=()
for id in "${old_ids[@]}"; do
  full_id="$(docker inspect --format '{{.Id}}' "$id")"
  [[ "$full_id" != "$candidate_id" ]] || continue
  source_image="$(docker inspect --format '{{.Config.Image}}' "$id")"
  owned_label="$(docker inspect --format '{{index .Config.Labels "io.nocturne.application"}}' "$id")"
  if [[ "$owned_label" != "$APP" && "$source_image" != atelier-nocturne:* ]]; then
    echo "Unrecognized container in old Nocturne project: $id. Stopping for review." >&2; exit 1
  fi
  owned_ids+=("$id")
done
old_ids=("${owned_ids[@]}")
if docker container inspect "$APP" >/dev/null 2>&1; then
  [[ "$(docker inspect --format '{{index .Config.Labels "io.nocturne.application"}}' "$APP")" == "$APP" ]] || { echo 'Container name is owned by another application.' >&2; exit 1; }
  docker rename "$APP" "${APP}-previous-$$"
  old_renamed="${APP}-previous-$$"
fi
for id in "${old_ids[@]}"; do
  if [[ "$(docker inspect --format '{{.State.Running}}' "$id")" == true ]]; then
    old_running+=("$id")
    docker stop --time 10 "$id" >/dev/null
  fi
done
final_created=1
phase=final-start
docker run -d "${runtime[@]}" --name "$APP" --restart unless-stopped -p "$bind:$port:8080" "$image" >/dev/null
phase=final-health
verify "http://127.0.0.1:$port" "$APP"
committed=1

# Remove previous app resources only after the replacement passes verification.
for id in "${old_ids[@]}"; do docker rm "$id" >/dev/null || true; done
docker rm -f "$candidate" >/dev/null
for project in nocturne-atelier atelier-nocturne; do
  while IFS= read -r network; do
    [[ -z "$network" ]] || docker network rm "$network" >/dev/null 2>&1 || true
  done < <(docker network ls -q --filter "label=com.docker.compose.project=$project")
done
while IFS= read -r old_tag; do
  [[ "$old_tag" == "$image" || "$old_tag" == *':<none>' ]] && continue
  docker image rm "$old_tag" >/dev/null 2>&1 || true
done < <(docker image ls --format '{{.Repository}}:{{.Tag}}' --filter reference='atelier-nocturne:*'; docker image ls --format '{{.Repository}}:{{.Tag}}' --filter reference='nocturne-atelier:*')

# Known legacy path from the previous instructions. Preserve the active checkout.
legacy=/opt/nocturne-atelier
if [[ "$release_dir" != "$legacy" && "$release_dir" != "$legacy/"* && ! -L "$legacy" && -f "$legacy/dist/index.html" ]] && grep -q 'Nocturne Atelier' "$legacy/dist/index.html"; then
  if ! mountpoint -q "$legacy"; then
    rm -rf --one-file-system -- "$legacy"
    echo 'CLEANED=/opt/nocturne-atelier'
  fi
fi
legacy_archive=/tmp/prod.tar.gz
if [[ "$release_dir/prod.tar.gz" != "$legacy_archive" && -f "$legacy_archive" && ! -L "$legacy_archive" ]]; then
  legacy_html="$(tar -xOf "$legacy_archive" ./dist/index.html 2>/dev/null || true)"
  if [[ "$legacy_html" == *'Nocturne Atelier'* ]]; then rm -f -- "$legacy_archive"; echo 'CLEANED=/tmp/prod.tar.gz'; fi
fi
echo "DEPLOY=PASS RELEASE=$release"
echo "URL=http://localhost:$port"
[[ "$bind" == 127.0.0.1 ]] || echo "NETWORK=Public interface, port $port"
