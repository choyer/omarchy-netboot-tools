#!/usr/bin/env bash
# update-omarchy-netboot.sh — stage an Omarchy ISO release for netbootxyz PXE boot
#
# Usage:
#   ./update-omarchy-netboot.sh [-s|--stream STABLE|DEV|EDGE|RC] <version> [expected_sha256]
#
# Examples:
#   ./update-omarchy-netboot.sh 4.0.5
#   ./update-omarchy-netboot.sh --stream STABLE 4.0.5 abcdef0123...
#   ./update-omarchy-netboot.sh --stream DEV 2026-09-15-build1
#
# What it does:
#   - STABLE (default): downloads https://iso.omarchy.org/omarchy-<version>.iso
#     into omarchy-iso/STABLE if not already present.
#   - DEV / EDGE / RC: these aren't hosted anywhere, so the script never tries
#     to download them — it expects you to have already built the ISO yourself
#     and placed it at omarchy-iso/<STREAM>/omarchy-<version>.iso. It errors
#     out with that exact expected path if the file isn't found.
#   - Either way: loop-mounts the ISO read-only and rsyncs the full tree into
#     its own versioned folder under netbootxyz's assets (omarchy-<version>/)
#     — this part always has to live there, since that's what nginx inside
#     the container actually serves for PXE boot.
#   - Atomically re-points the "omarchy" symlink at that new versioned folder,
#     so the custom iPXE menu entry (which always references .../omarchy/...)
#     never needs to be edited, whichever stream you staged.
#
# Run this on the TrueNAS host itself (SSH or System > Shell), as root.
# Recommended location: /mnt/PixoNet-Block/omarchy-iso/scripts/

set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 [-s|--stream STABLE|DEV|EDGE|RC] <version> [expected_sha256]

  -s, --stream   Release stream to stage (default: STABLE)
  <version>      Release version/tag, e.g. 4.0.5 or a DEV/EDGE/RC build label
  [expected_sha256]   Optional checksum to verify

Examples:
  $0 4.0.5
  $0 --stream STABLE 4.0.5 abcdef0123...
  $0 --stream DEV 2026-09-15-build1
EOF
  exit 1
}

STREAM="STABLE"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--stream)
      STREAM="${2:?Missing stream value}"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      break
      ;;
  esac
done

VERSION="${1:-}"
[ -n "$VERSION" ] || usage
EXPECTED_SHA256="${2:-}"

STREAM_UPPER=$(echo "$STREAM" | tr '[:lower:]' '[:upper:]')
case "$STREAM_UPPER" in
  STABLE|DEV|EDGE|RC) ;;
  *) echo "Unknown stream: $STREAM (expected STABLE, DEV, EDGE, or RC)"; exit 1 ;;
esac

ISO_DIR="/mnt/PixoNet-Block/omarchy-iso/${STREAM_UPPER}"
ASSETS_ROOT="/mnt/PixoNet-Block/netbootxyz/assets"
EXTRACT_DIR="${ASSETS_ROOT}/omarchy-${VERSION}"
LIVE_LINK="${ASSETS_ROOT}/omarchy"
ISO_PATH="${ISO_DIR}/omarchy-${VERSION}.iso"

mkdir -p "$ISO_DIR"

if [ "$STREAM_UPPER" = "STABLE" ]; then
  ISO_URL="https://iso.omarchy.org/omarchy-${VERSION}.iso"
  if [ -f "$ISO_PATH" ]; then
    echo "ISO already present: $ISO_PATH (skipping download)"
  else
    echo "Downloading $ISO_URL ..."
    curl -L -o "$ISO_PATH" "$ISO_URL"
  fi
else
  # DEV/EDGE/RC builds aren't hosted anywhere — must be built and placed manually first.
  if [ ! -f "$ISO_PATH" ]; then
    echo "ERROR: ${STREAM_UPPER} ISO not found at ${ISO_PATH}"
    echo "${STREAM_UPPER} builds aren't hosted anywhere — build it yourself and place it there first, named:"
    echo "  omarchy-${VERSION}.iso"
    exit 1
  fi
  echo "Using locally-built ${STREAM_UPPER} ISO: $ISO_PATH"
fi

if [ -n "$EXPECTED_SHA256" ]; then
  echo "Verifying checksum..."
  echo "${EXPECTED_SHA256}  ${ISO_PATH}" | sha256sum -c -
else
  echo "No checksum supplied — skipping verification. Actual sha256:"
  sha256sum "$ISO_PATH"
fi

echo "Extracting into ${EXTRACT_DIR} ..."
MOUNT_TMP="$(mktemp -d)"
mount -o loop,ro "$ISO_PATH" "$MOUNT_TMP"
mkdir -p "$EXTRACT_DIR"
rsync -a --delete "$MOUNT_TMP/" "$EXTRACT_DIR/"
umount "$MOUNT_TMP"
rmdir "$MOUNT_TMP"

chown -R 1000:1000 "$EXTRACT_DIR"

echo "Re-pointing ${LIVE_LINK} -> omarchy-${VERSION}"
ln -sfn "omarchy-${VERSION}" "$LIVE_LINK"

echo ""
echo "Done (${STREAM_UPPER} build). Confirm it's reachable at:"
echo "  http://boot.quattro.01x.ca/omarchy/arch/boot/x86_64/vmlinuz-linux-t2"
echo ""
echo "Old versioned folders under ${ASSETS_ROOT} are left in place for rollback —"
echo "delete any you no longer need manually (e.g. rm -rf ${ASSETS_ROOT}/omarchy-<old-version>)."
