#!/usr/bin/env bash
set +e
RES=/root/fd-start-probe.txt
SERIAL=/dev/ttyS0
BIN=/opt/firedancer/bin
CFG=/opt/firedancer/fd-vm.toml
# scratch_directory from fd-vm.toml; identity.json defaults here per default.toml.
SCRATCH=/var/lib/firedancer/fdvm

{
echo "===FD-START-PROBE-START==="
date -u
echo "kernel: $(uname -r)"
echo "nproc: $(nproc)"
echo "MemTotal: $(grep MemTotal /proc/meminfo | awk '{print $2,$3}')"
echo ""
echo "---- network interfaces (before bringup) ----"
ip -br link 2>/dev/null
echo "ip route get 8.8.8.8: $(ip route get 8.8.8.8 2>&1 | head -1)"
echo ""
echo "---- [1] defensively bring up enp0s2 ----"
ip link set enp0s2 up 2>&1
# try dhclient, then a static fallback (QEMU user-net DHCP gives 10.0.2.15/24, gw 10.0.2.2)
if command -v dhclient >/dev/null 2>&1; then
  dhclient enp0s2 2>&1 | head -3
else
  # no dhclient: assign the QEMU user-net default address manually
  ip addr add 10.0.2.15/24 dev enp0s2 2>&1
  ip route add default via 10.0.2.2 2>&1
fi
sleep 2
echo "ip -br addr after bringup:"
ip -br addr 2>/dev/null
echo "ip route get 8.8.8.8: $(ip route get 8.8.8.8 2>&1 | head -1)"
echo ""
echo "---- [2] fdctl version ----"
"$BIN/fdctl" --config "$CFG" version 2>&1 | head -8
echo ""
echo "---- [3] sysfs state BEFORE configure ----"
echo "nr_hugepages(before): $(cat /proc/sys/vm/nr_hugepages 2>/dev/null)"
echo "hugepages-2048kB/nr_hugepages(before): $(cat /sys/devices/system/node/node0/hugepages/hugepages-2048kB/nr_hugepages 2>/dev/null)"
echo "mounts(before) hugetlbfs: $(mount 2>/dev/null | grep hugetlbfs || echo none)"
echo ""
echo "---- [4] fdctl configure init hugetlbfs (the real gate) ----"
"$BIN/fdctl" --config "$CFG" configure init hugetlbfs 2>&1
hugetlbfs_rc=$?
echo "configure init hugetlbfs exit=$hugetlbfs_rc"
echo ""
echo "---- [5] fdctl configure init sysctl ----"
"$BIN/fdctl" --config "$CFG" configure init sysctl 2>&1
sysctl_rc=$?
echo "configure init sysctl exit=$sysctl_rc"
echo ""
echo "---- [6] sysfs state AFTER configure ----"
echo "nr_hugepages(after): $(cat /proc/sys/vm/nr_hugepages 2>/dev/null)"
echo "hugepages-2048kB/nr_hugepages(after): $(cat /sys/devices/system/node/node0/hugepages/hugepages-2048kB/nr_hugepages 2>/dev/null)"
echo "mounts(after) hugetlbfs:"
mount 2>/dev/null | grep hugetlbfs || echo "  (none)"
echo ""
echo "---- [7] fdctl configure check all ----"
"$BIN/fdctl" --config "$CFG" configure check all 2>&1
check_rc=$?
echo "configure check all exit=$check_rc"
echo ""
# If hugetlbfs configure PASSED, attempt to start the validator for a short
# window to prove the process can actually start (the `started` claim).
# This is the strongest honest evidence reachable under TCG.
run_rc=-1
if [ "$hugetlbfs_rc" -eq 0 ]; then
  echo "---- [8] pre-generate identity key (fdctl run needs it pre-existing) ----"
  # run_firedancer_init (run.c:1051) errors ENOENT if the identity key is absent.
  # fdctl does NOT have the dev-only 'genesis'/'keys' configure stages (only
  # fddev does), so fdctl run cannot auto-create one. Generate it explicitly.
  IDKEY=$( "$BIN/fdctl" --config "$CFG" print-config-path 2>/dev/null | grep -i identity_key || true )
  # Default identity_key path when unset: scratch_directory/identity.json.
  # CRITICAL: do NOT `mkdir -p` here as root — generate_keypair (keys.c:90)
  # does seteuid(target_uid=1000) then open(...,O_CREAT). If the dir exists
  # but is root-owned 0755, the seteuid(1000) write hits EACCES (this is what
  # failed in fd-start17). fd_file_util_mkdir_all only chowns dirs it creates,
  # so an existing root-owned dir stays root-owned. Fix: create the dir as
  # root (allowed) then chown it to fdtest:fdtest so the seteuid write works.
  BASE="$SCRATCH"
  IDPATH="$BASE/identity.json"
  mkdir -p "$BASE"
  chown -R fdtest:fdtest "$BASE" 2>/dev/null || true
  if [ ! -f "$IDPATH" ]; then
    "$BIN/fdctl" --config "$CFG" keys new "$IDPATH" 2>&1 | head -10
  fi
  echo "identity key: $(ls -la "$IDPATH" 2>/dev/null || echo MISSING)"
  echo ""
  echo "---- [9] fdctl run (180s timeout — full untruncated started-evidence attempt) ----"
  # fdctl run with bootstrap=true passes the entrypoints check (run.c:1469),
  # then run_firedancer_init checks the identity key exists (run.c:1051),
  # emits the kworkers/cpuset warnings (run.c:1015/1040), calls
  # initialize_workspaces (hugepage-backed shared mem for all tiles) and
  # initialize_stacks, then run_firedancer forks the Firedancer tiles
  # (clone_firedancer, run.c:1410) and exec's the embedded Agave
  # (execve_agave, run.c:146). With snapshot_fetch/genesis_fetch/poh_speed_test
  # all disabled, a bootstrap node with no genesis.bin will fail inside the
  # Agave subprocess at genesis load — we capture the FULL output (no head
  # truncation) for 180s to see exactly where it stops. RUST_BACKTRACE=full so
  # any Agave panic prints a stack. tee to a dedicated run log so nothing is
  # lost to the serial ring buffer.
  echo "ledger dir before run:"
  ls -la "$SCRATCH/ledger" 2>&1 | head -20 || echo "  (no ledger dir)"
  echo "genesis.bin before run: $(ls -la "$SCRATCH/ledger/genesis.bin" 2>/dev/null || echo MISSING)"
  # Clear dmesg ring and snapshot it right before the run, so any kernel-level
  # kill (SIGSYS=31 from a SECCOMP_RET_KILL_PROCESS, OOM, SIGSEGV, etc.) is
  # captured with the offending syscall/PID. fdctl run exit=31 with zero Agave
  # stdout is the open mystery — dmesg is the decisive diagnostic.
  dmesg -C 2>/dev/null || true
  RUST_BACKTRACE=full timeout 180 "$BIN/fdctl" --config "$CFG" run > "$SCRATCH/fdctl-run.log" 2>&1
  run_rc=$?
  echo "--- fdctl-run.log (full) ---"
  cat "$SCRATCH/fdctl-run.log"
  echo "--- end log ---"
  echo "--- dmesg (during run) ---"
  dmesg 2>/dev/null | tail -40 || echo "  (dmesg unavailable)"
  echo "--- end dmesg ---"
  echo "ledger dir after run:"
  ls -la "$SCRATCH/ledger" 2>&1 | head -20 || echo "  (no ledger dir)"
  echo "fdctl-run exit=$run_rc (124=timeout/killed=likely-started; 1=early-config-error; 0=clean-exit; 31=SIGSYS/seccomp-kill suspected)"
fi
echo ""
echo "===FD-START-PROBE-END==="
echo "SUMMARY: hugetlbfs_rc=$hugetlbfs_rc sysctl_rc=$sysctl_rc check_rc=$check_rc run_rc=$run_rc"
} > "$RES" 2>&1
cat "$RES" > "$SERIAL" 2>/dev/null || true
