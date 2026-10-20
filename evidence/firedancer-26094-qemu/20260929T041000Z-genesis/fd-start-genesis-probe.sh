#!/usr/bin/env bash
set +e
RES=/root/fd-start-genesis-probe.txt
SERIAL=/dev/ttyS0
BIN=/opt/firedancer/bin
CFG=/opt/firedancer/fd-vm.toml
AGAVE=/opt/agave/bin
SCRATCH=/var/lib/firedancer/fdvm
LEDGER="$SCRATCH/ledger"

{
echo "===FD-START-GENESIS-PROBE-START==="
date -u
echo "kernel: $(uname -r)"
echo "nproc: $(nproc)"
echo "cpu flags (AVX?): $(grep -oE 'avx[0-9a-z]*' /proc/cpuinfo | sort -u | tr '\n' ' ')"
echo "MemTotal: $(grep MemTotal /proc/meminfo | awk '{print $2,$3}')"
echo ""
echo "---- [0] network bringup ----"
ip link set enp0s2 up 2>&1
if command -v dhclient >/dev/null 2>&1; then
  dhclient enp0s2 2>&1 | head -3
else
  ip addr add 10.0.2.15/24 dev enp0s2 2>&1
  ip route add default via 10.0.2.2 2>&1
fi
sleep 2
echo "ip -br addr: $(ip -br addr 2>/dev/null | grep enp0s2)"
echo ""

echo "---- [1] agave-tools present? ----"
ls -la "$AGAVE/solana-test-validator" "$AGAVE/solana-keygen" 2>&1
"$AGAVE/solana-keygen" --version 2>&1 | head -2
echo ""

echo "---- [2] fdctl version ----"
"$BIN/fdctl" --config "$CFG" version 2>&1 | head -4
echo ""

echo "---- [3] sysfs state BEFORE configure ----"
echo "nr_hugepages(before): $(cat /proc/sys/vm/nr_hugepages 2>/dev/null)"
echo "node0 hugepages: $(cat /sys/devices/system/node/node0/hugepages/hugepages-2048kB/nr_hugepages 2>/dev/null)"
echo ""

echo "---- [4] fdctl configure init hugetlbfs ----"
"$BIN/fdctl" --config "$CFG" configure init hugetlbfs 2>&1
hugetlbfs_rc=$?
echo "configure init hugetlbfs exit=$hugetlbfs_rc"
echo ""

echo "---- [5] fdctl configure init sysctl ----"
"$BIN/fdctl" --config "$CFG" configure init sysctl 2>&1
sysctl_rc=$?
echo "configure init sysctl exit=$sysctl_rc"
echo ""

echo "---- [6] fdctl configure check all ----"
"$BIN/fdctl" --config "$CFG" configure check all 2>&1
check_rc=$?
echo "configure check all exit=$check_rc"
echo ""

run_rc=-1
genesis_rc=-1
if [ "$hugetlbfs_rc" -eq 0 ]; then

  echo "---- [7] ensure identity key exists ----"
  BASE="$SCRATCH"
  IDPATH="$BASE/identity.json"
  mkdir -p "$BASE"
  chown -R fdtest:fdtest "$BASE" 2>/dev/null || true
  if [ ! -f "$IDPATH" ]; then
    "$BIN/fdctl" --config "$CFG" keys new "$IDPATH" 2>&1 | head -10
  fi
  echo "identity key: $(ls -la "$IDPATH" 2>/dev/null || echo MISSING)"
  echo ""

  echo "---- [8] generate genesis.bin via solana-test-validator ----"
  # solana-test-validator creates a genesis.bin in its ledger dir. We use it
  # ONLY as a genesis generator (genesis construction is
  # create_genesis_config_with_leader_ex, runtime/src/genesis_utils.rs:533 --
  # NOT the plain create_genesis_config helper; see
  # knowledge/solana-test-validator.md), NOT as the validator under test. The
  # generated genesis.bin is the standard Agave 4.3.0 genesis format,
  # compatible with the Firedancer-embedded Agave (submodule 535ec972, v4.3.0-fd).
  #
  # QEMU -cpu max exposes AVX (unlike Rosetta), so the x86_64
  # solana-test-validator binary can run here.
  rm -rf /tmp/gen-ledger
  mkdir -p /tmp/gen-ledger
  # --reset ensures a fresh genesis; --bpf-program none. Let it create genesis
  # then bind; we poll for genesis.bin and kill it.
  timeout 90 "$AGAVE/solana-test-validator" --reset --ledger /tmp/gen-ledger > /tmp/tv.log 2>&1 &
  TVPID=$!
  genesis_ready=0
  for i in $(seq 1 75); do
    if [ -f /tmp/gen-ledger/genesis.bin ]; then
      genesis_ready=1
      echo "GENESIS_BIN_READY after ${i}s"
      break
    fi
    # if the process already died, break
    if ! kill -0 $TVPID 2>/dev/null; then
      echo "solana-test-validator exited early (before genesis ready) after ${i}s"
      break
    fi
    sleep 1
  done
  kill $TVPID 2>/dev/null || true
  wait $TVPID 2>/dev/null || true
  if [ "$genesis_ready" -eq 1 ]; then
    genesis_rc=0
    # Place genesis.bin where the Firedancer-embedded Agave looks for it.
    mkdir -p "$LEDGER"
    cp /tmp/gen-ledger/genesis.bin "$LEDGER/genesis.bin"
    chown -R fdtest:fdtest "$LEDGER" 2>/dev/null || true
    echo "genesis.bin placed at $LEDGER/genesis.bin"
    ls -la "$LEDGER/genesis.bin"
    # Also capture the genesis hash for the record.
    "$AGAVE/agave-ledger-tool" --ledger /tmp/gen-ledger genesis-hash 2>&1 | tail -2
  else
    genesis_rc=1
    echo "GENESIS GENERATION FAILED"
    echo "--- tv.log (head) ---"
    head -30 /tmp/tv.log 2>&1
    echo "--- tv.log (tail) ---"
    tail -20 /tmp/tv.log 2>&1
  fi
  echo "genesis_rc=$genesis_rc"
  echo ""

  if [ "$genesis_rc" -eq 0 ]; then
    echo "---- [9] fdctl run (with genesis.bin present; 240s timeout) ----"
    # With snapshot_fetch/genesis_fetch/poh disabled, bootstrap=true, and a
    # genesis.bin now present, the embedded Agave should load the genesis
    # (open.rs) and proceed further than before (bank creation, bank frozen
    # event, leader schedule, gossip). Under TCG this is slow; 240s gives it
    # room. RUST_BACKTRACE=full for any Agave panic. tee to a dedicated log.
    dmesg -C 2>/dev/null || true
    RUST_BACKTRACE=full timeout 240 "$BIN/fdctl" --config "$CFG" run > "$SCRATCH/fdctl-run-genesis.log" 2>&1
    run_rc=$?
    echo "--- fdctl-run-genesis.log (head 60) ---"
    head -60 "$SCRATCH/fdctl-run-genesis.log"
    echo "--- fdctl-run-genesis.log (tail 80) ---"
    tail -80 "$SCRATCH/fdctl-run-genesis.log"
    echo "--- dmesg (during run) ---"
    dmesg 2>/dev/null | tail -40 || echo "  (dmesg unavailable)"
    echo "--- end dmesg ---"
    echo "ledger dir after run:"
    ls -la "$LEDGER" 2>&1 | head -20
    echo "fdctl-run exit=$run_rc (124=timeout=likely-progressing; 0=clean-exit; 1=early-error; 31=SIGSYS/seccomp)"
  fi
fi
echo ""
echo "===FD-START-GENESIS-PROBE-END==="
echo "SUMMARY: hugetlbfs_rc=$hugetlbfs_rc sysctl_rc=$sysctl_rc check_rc=$check_rc genesis_rc=$genesis_rc run_rc=$run_rc"
} > "$RES" 2>&1
cat "$RES" > "$SERIAL" 2>/dev/null || true
