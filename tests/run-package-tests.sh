#!/bin/bash
set -euo pipefail

profile=${1:?Usage: run-package-tests.sh PROFILE UBUNTU_VERSION}
ubuntu_version=${2:?Missing Ubuntu version}
image="nginx-package-test:$profile"
container="nginx-package-test-$profile-$$"
package_file=$(cat "output/$profile/package-file.txt")

cleanup() {
    status=$?
    if (( status != 0 )); then
        docker logs "$container" >&2 || true
        docker exec "$container" journalctl -u nginx --no-pager >&2 || true
        docker exec "$container" cat /var/log/nginx/error.log >&2 || true
    fi
    docker rm -f "$container" >/dev/null 2>&1 || true
    exit "$status"
}
trap cleanup EXIT

docker build --build-arg "UBUNTU_VERSION=$ubuntu_version" \
    -f tests/Dockerfile -t "$image" .
docker run -d --name "$container" --privileged --cgroupns=private \
    --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
    -v "$PWD/output/$profile:/packages:ro" \
    -v "$PWD/tests:/checks:ro" "$image"

for ((attempt=0; attempt<30; attempt++)); do
    if docker exec "$container" systemctl show-environment >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
docker exec "$container" systemctl show-environment >/dev/null
docker exec -e "PACKAGE_FILE=$package_file" "$container" bash /checks/package-smoke.sh
