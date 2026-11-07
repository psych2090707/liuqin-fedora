#!/usr/bin/env bash
# Host wrapper: run packaging/mobile/verify-in-container.sh in the arm64 container.
set -euo pipefail
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
container=${CONTAINER:-mbuilder}
sudo -n podman container exists "$container" || {
  sudo -n podman run -d --name "$container" --arch arm64 --network=host \
    -v "$project_root":/work:z registry.fedoraproject.org/fedora:45 sleep infinity >/dev/null
}
sudo -n podman cp "$project_root/packaging/mobile/verify-in-container.sh" \
    "$container":/root/verify-in-container.sh
sudo -n podman exec "$container" bash /root/verify-in-container.sh
