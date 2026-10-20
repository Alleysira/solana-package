#!/usr/bin/env python3
"""fd-start-genesis: probe whether the embedded Agave loads a genesis.bin.

The prior probe (fd-start25) reached genesis-config load (open.rs(25)) but
had no genesis.bin, so the embedded Agave could not complete genesis load.
This probe:
  1. Boots the VM (standard kernel 6.8.0-142-generic, 16 vCPU, 64 GiB, TCG).
  2. The systemd unit fd-start-probe.service runs
     /usr/local/bin/fd-start-genesis-probe.sh, which:
       a. configures init hugetlbfs/sysctl/check (the proven gate path),
       b. generates a genesis.bin via solana-test-validator (AVX available
          under QEMU -cpu max, unlike Rosetta),
       c. places it at /var/lib/firedancer/fdvm/ledger/genesis.bin,
       d. runs fdctl run (240s) with the genesis present.

QEMU -cpu max exposes AVX (unlike Rosetta), so the x86_64
solana-test-validator binary from the agave-tools image can run here.

Honest ceiling under TCG (x86_64-on-arm64, no KVM): `started` was reached
prior; with a genesis.bin present we test whether the embedded Agave gets
PAST genesis load (bank creation / bank-frozen / leader schedule / gossip).
`voting` is not expected (TCG is too slow to keep up with slots).
"""
import socket, subprocess, time, sys, os

SOCK = "/tmp/fd-vm/serial-genesis.sock"
OUT  = "/tmp/fd-vm/console-genesis.txt"
QEMU = "/opt/homebrew/bin/qemu-system-x86_64"
# 18 min — TCG boot (16 vCPU) + genesis generation (~30-60s) + 240s fdctl run + margin
WAIT = 1080

try: os.unlink(SOCK)
except FileNotFoundError: pass

proc = subprocess.Popen(
    [QEMU,
     "-name", "fd-start-genesis",
     "-machine", "q35,accel=tcg",
     "-cpu", "max",
     "-smp", "16",
     "-m", "65536",
     "-drive", "file=/tmp/fd-vm/ubuntu-noble.qcow2,if=virtio,format=qcow2",
     "-netdev", "user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22",
     "-device", "virtio-net-pci,netdev=net0",
     "-nographic",
     "-serial", f"unix:{SOCK},server,nowait",
     "-monitor", "none",
    ],
    stdout=open("/tmp/fd-vm/qemu-genesis.log","w"),
    stderr=subprocess.STDOUT,
)
print(f"QEMU pid={proc.pid}", flush=True)

s = None
for attempt in range(60):
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(2)
        s.connect(SOCK)
        print(f"connected to serial socket on attempt {attempt+1}", flush=True)
        break
    except Exception:
        s = None
        time.sleep(1)
if s is None:
    print("ERROR: could not connect to serial socket", flush=True)
    proc.kill()
    sys.exit(1)

buf = b""
s.setblocking(False)
end = time.time() + WAIT
last_print = 0
while time.time() < end:
    if proc.poll() is not None:
        print(f"QEMU exited early with code {proc.returncode}", flush=True)
        break
    try:
        chunk = s.recv(65536)
        if chunk:
            buf += chunk
    except (BlockingIOError, OSError):
        time.sleep(0.3)
    now = time.time()
    if now - last_print > 30:
        text = buf.decode("utf-8", errors="replace")
        has_summary = "SUMMARY:" in text
        has_start = "===FD-START-GENESIS-PROBE-START===" in text
        last_line = text.strip().splitlines()[-1] if text.strip() else "(empty)"
        print(f"[t={int(now-(end-WAIT))}s] {len(buf)} bytes, start={has_start} summary={has_summary}, last: {last_line[:90]}", flush=True)
        last_print = now
        if has_summary:
            print("PROBE COMPLETE (SUMMARY seen) — draining 20 more seconds", flush=True)
            time.sleep(20)
            try:
                while True:
                    chunk = s.recv(65536)
                    if not chunk: break
                    buf += chunk
            except (BlockingIOError, OSError):
                pass
            break

text = buf.decode("utf-8", errors="replace")
with open(OUT, "w") as f:
    f.write(text)
print(f"\n=== wrote {len(text)} bytes to {OUT} ===", flush=True)

for line in text.splitlines():
    stripped = line.strip()
    if any(k in stripped for k in ["nproc:", "MemTotal:", "AVX", "configure init hugetlbfs exit",
                                    "configure init sysctl exit", "configure check all exit",
                                    "GENESIS_BIN_READY", "GENESIS GENERATION FAILED", "genesis_rc",
                                    "fdctl-run exit", "SUMMARY", "keys.c", "run.c",
                                    "ERR", "ERROR", "error:", "identity key",
                                    "open.rs", "genesis.bin", "bank", "Bank", "frozen",
                                    "leader", "schedule", "gossip", "cluster",
                                    "vote", "slot", "PoH", "poh", "started",
                                    "agave", "genesis", "booting", "WARNING",
                                    "genesis-hash", "USAGE", "required arguments",
                                    "bank-frozen", "BankFrozen", "fork", "snapshot"]):
        print(f"  {stripped[:160]}")

if "nproc: 16" in text:
    print("\n>>> CONFIRMED: 16-vCPU boot probe fired")
else:
    print("\n>>> WARNING: no nproc:16 marker found (probe may not have fired)")

s.close()
print(f"killing QEMU pid={proc.pid}", flush=True)
proc.kill()
try:
    proc.wait(timeout=15)
except Exception:
    pass
print("QEMU terminated.", flush=True)
