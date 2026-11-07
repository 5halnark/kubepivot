#!/usr/bin/env bash
# Build the KubePivot image and (optionally) load it onto a local cluster.
#
#   ./scripts/build-image.sh                 # just build  kubepivot:latest
#   LOADER=kind   ./scripts/build-image.sh    # build + kind load
#   LOADER=minikube ./scripts/build-image.sh  # build + minikube image load
#   IMAGE=ghcr.io/you/kubepivot:1.0.0 PUSH=1 ./scripts/build-image.sh  # build + push
set -euo pipefail

IMAGE="${IMAGE:-kubepivot:latest}"
cd "$(dirname "$0")/.."

echo "[*] Building ${IMAGE}"
docker build -t "${IMAGE}" .

case "${LOADER:-}" in
  kind)      echo "[*] kind load"     ; kind load docker-image "${IMAGE}" ;;
  minikube)  echo "[*] minikube load" ; minikube image load "${IMAGE}" ;;
esac

if [ "${PUSH:-0}" = "1" ]; then
  echo "[*] Pushing ${IMAGE}"
  docker push "${IMAGE}"
fi

echo "[*] Done."
