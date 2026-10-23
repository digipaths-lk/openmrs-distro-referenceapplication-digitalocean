#!/bin/bash
# Nightly rebuild of the OpenMRS distro:
#   1. update the distro and patient-chart checkouts
#   2. build + npm pack the custom chart modules in a throwaway Node container
#   3. copy the tarballs into the distro's frontend/ (gitignored there) and
#      docker compose build / up -d
#
# Run by openmrs-nightly.service with /etc/openmrs-nightly/settings as its
# environment; safe to run by hand as root.
#
# The body is wrapped in main() because `git pull` of this deploy repo may rewrite
# this very file; bash reads scripts incrementally, so the whole function must be
# parsed first.

main() {
  set -euo pipefail

  local base="${OPENMRS_BASE:-/opt/openmrs}"
  local distro="$base/distro" chart="$base/chart" deploy="$base/deploy"
  local tgz="${TGZ_DIR:-/opt/frontend-tgz}"
  local distro_branch="${DISTRO_BRANCH:-clinicalview}"
  local chart_branch="${CHART_BRANCH:-main}"
  local wipe_data="${WIPE_DATA:-false}"

  update() {
    echo "==> Updating $1 to origin/$2"
    git -C "$1" fetch --prune origin
    git -C "$1" checkout -B "$2" "origin/$2"
    git -C "$1" log -1 --format='    %h %s (%an, %ad)'
  }

  # Self-update: takes effect on the next run
  git -C "$deploy" pull --ff-only || echo "WARN: could not update $deploy" >&2

  update "$chart" "$chart_branch"
  update "$distro" "$distro_branch"

  echo "==> Building custom frontend modules from $chart"
  rm -f "$tgz"/openmrs-esm-patient-chart-app-*.tgz \
        "$tgz"/openmrs-esm-form-engine-app-*.tgz \
        "$tgz"/openmrs-esm-patient-digipaths-app-*.tgz
  docker run --rm \
    -v "$chart":/src -v "$tgz":/out -v openmrs-yarn-cache:/yarn-cache \
    -e YARN_CACHE_FOLDER=/yarn-cache -e COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
    -w /src node:22 sh -euc '
      corepack enable
      yarn install --immutable
      yarn turbo run build \
        --filter=@openmrs/esm-patient-chart-app \
        --filter=@openmrs/esm-form-engine-app \
        --filter=@openmrs/esm-patient-digipaths-app
      for p in esm-patient-chart-app esm-form-engine-app esm-patient-digipaths-app; do
        (cd packages/$p && npm pack --pack-destination /out)
      done'

  # The distro's frontend/Dockerfile COPYs exact versioned filenames. Check them all
  # up front so a version mismatch between the two repos fails with a clear message.
  local missing=0 f
  for f in $(grep -oE 'openmrs-esm-[^ ]+\.tgz' "$distro/frontend/Dockerfile"); do
    if [ ! -f "$tgz/$f" ]; then
      echo "ERROR: $distro/frontend/Dockerfile needs $f, not found in $tgz" >&2
      missing=1
    fi
  done
  if [ "$missing" = 1 ]; then
    echo "Available: $(cd "$tgz" && ls *.tgz | tr '\n' ' ')" >&2
    echo "Bump the versions in the distro (Dockerfile + spa-assemble-config.json) or upload the file." >&2
    exit 1
  fi
  rm -f "$distro"/frontend/*.tgz
  cp "$tgz"/*.tgz "$distro/frontend/"

  cd "$distro"
  echo "==> Building images (old stack keeps running meanwhile)"
  docker compose build --pull --build-arg CACHE_BUST="$(date +%s)"

  if [ "$wipe_data" = "true" ]; then
    echo "==> WIPE_DATA=true: removing containers and data volumes"
    # Keep the Let's Encrypt volume so we don't hit certificate rate limits
    docker compose down
    local project
    project="$(docker compose config | awk '/^name:/{print $2}')"
    docker volume rm -f "${project}_db-data" "${project}_openmrs-data"
  fi

  echo "==> Starting stack"
  docker compose up -d --remove-orphans

  echo "==> Cleaning up old images and build cache"
  docker image prune -f
  docker builder prune -f --filter until=72h

  echo "==> Done. Backend may take several minutes to finish starting."
}

main "$@"
exit
