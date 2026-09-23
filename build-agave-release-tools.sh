#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

image="${AGAVE_TOOLS_IMAGE:-solana-diff/agave-tools:4.3.0-amd64}"
archive_sha256="c97289a8abb1d0efb497d8b5cb285baabd9b7f8ea6647f5d145c5dc8ff3611e8"
download_dir="$(mktemp -d /tmp/agave-release-tools.XXXXXX)"
cleanup() {
  case "$download_dir" in
    /tmp/agave-release-tools.*) rm -rf -- "$download_dir" ;;
  esac
}
trap cleanup EXIT

curl --proto '=https' --tlsv1.2 --fail --show-error --location \
  --output "$download_dir/agave.tar.bz2" \
  https://github.com/anza-xyz/agave/releases/download/v4.3.0/solana-release-x86_64-unknown-linux-gnu.tar.bz2
printf '%s  %s\n' "$archive_sha256" "$download_dir/agave.tar.bz2" | shasum -a 256 --check

docker buildx build --platform linux/amd64 --load \
  --build-context "agave_archive=$download_dir" \
  --file Dockerfile.agave-release-tools --tag "$image" .

docker run --rm --platform linux/amd64 "$image" --version
if docker run --rm --platform linux/amd64 --entrypoint sh "$image" \
    -c 'test -e /opt/agave/bin/agave-validator'; then
  echo "Release tools image unexpectedly contains agave-validator." >&2
  exit 1
fi
