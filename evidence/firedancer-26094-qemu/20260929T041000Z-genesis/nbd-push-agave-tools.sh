#!/usr/bin/env bash
# Push the agave-tools tar into the qcow2 VM disk at /opt/agave/, so the VM
# (x86_64, -cpu max -> AVX available, unlike Rosetta) can run
# solana-test-validator to generate a genesis.bin for Firedancer to load.
set -e
QCOW=/tmp/fd-vm/ubuntu-noble.qcow2
TAR=/tmp/fd-vm/agave-tools/agave.tar

docker --context orbstack run --rm --platform linux/amd64 --privileged \
  -v "$QCOW:/disk.qcow2" \
  -v "$TAR:/host/agave.tar:ro" \
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
    echo "=== before push: /opt ==="
    ls -la /mnt/root/opt/ 2>&1 | head
    echo "=== extracting agave tools to /opt/agave ==="
    mkdir -p /mnt/root/opt/agave
    tar xf /host/agave.tar -C /mnt/root/opt/ 2>&1
    echo "=== after push: /opt/agave/bin ==="
    ls -la /mnt/root/opt/agave/bin/ 2>&1 | head -20
    echo "=== libs present? (solana-test-validator needs libssl etc) ==="
    ls /mnt/root/usr/lib/x86_64-linux-gnu/libssl* 2>&1 | head
    ls /mnt/root/usr/lib/x86_64-linux-gnu/libudev* 2>&1 | head
    ls /mnt/root/usr/lib/x86_64-linux-gnu/libstdc++* 2>&1 | head
    echo "=== disk free in VM ==="
    df -h /mnt/root 2>&1 | tail -2
    sync
    umount /mnt/root
    qemu-nbd --disconnect /dev/nbd0
    echo "NBD-PUSH-AGAVE-TOOLS-OK"
  '
