#!/usr/bin/env bash
# Push the genesis probe script to the EXACT paths the systemd unit invokes:
# /usr/local/bin/fd-start-probe.sh  (ExecStart in fd-start-probe.service)
# /opt/firedancer/fd-start-probe.sh (kept in sync)
set -e
QCOW=/tmp/fd-vm/ubuntu-noble.qcow2
PROBE=/tmp/fd-vm/fd-start-genesis-probe.sh

docker --context orbstack run --rm --platform linux/amd64 --privileged \
  -v "$QCOW:/disk.qcow2" \
  -v "$PROBE:/host/fd-start-genesis-probe.sh:ro" \
  debian:bookworm bash -eu -c '
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq qemu-utils e2fsprogs util-linux >/dev/null 2>&1
    modprobe nbd max_part=8 2>/dev/null || true
    qemu-nbd --connect=/dev/nbd0 /disk.qcow2
    sleep 1
    blockdev --rereadpt /dev/nbd0 2>/dev/null || true
    PRT=/dev/nbd0p1
    if [ ! -b "$PRT" ]; then
      read MAJ MIN < <(awk "/nbd0p1/ {print \$1, \$2}" /proc/partitions)
      mknod "$PRT" b "$MAJ" "$MIN"
    fi
    e2fsck -f -y "$PRT" >/dev/null 2>&1 || true
    mkdir -p /mnt/root
    mount -t ext4 "$PRT" /mnt/root
    # Overwrite BOTH paths the unit/older-probe used, so the systemd unit runs
    # the genesis probe on next boot.
    cp /host/fd-start-genesis-probe.sh /mnt/root/usr/local/bin/fd-start-probe.sh
    cp /host/fd-start-genesis-probe.sh /mnt/root/opt/firedancer/fd-start-probe.sh
    chmod 0755 /mnt/root/usr/local/bin/fd-start-probe.sh
    chmod 0755 /mnt/root/opt/firedancer/fd-start-probe.sh
    # Also keep the named probe in sync (harmless).
    cp /host/fd-start-genesis-probe.sh /mnt/root/usr/local/bin/fd-start-genesis-probe.sh
    cp /host/fd-start-genesis-probe.sh /mnt/root/opt/firedancer/fd-start-genesis-probe.sh
    chmod 0755 /mnt/root/usr/local/bin/fd-start-genesis-probe.sh
    chmod 0755 /mnt/root/opt/firedancer/fd-start-genesis-probe.sh
    echo "=== verify the genesis probe is now at the unit path ==="
    head -3 /mnt/root/usr/local/bin/fd-start-probe.sh
    grep -c "GENESIS_BIN_READY" /mnt/root/usr/local/bin/fd-start-probe.sh
    echo "=== verify agave-tools still present ==="
    ls -la /mnt/root/opt/agave/bin/solana-test-validator 2>&1 | head -2
    sync
    umount /mnt/root
    qemu-nbd --disconnect /dev/nbd0
    echo "NBD-PUSH-GENESIS-PROBE2-OK"
  '
