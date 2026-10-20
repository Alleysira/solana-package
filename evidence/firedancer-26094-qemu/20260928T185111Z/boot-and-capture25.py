#!/usr/bin/env python3
"""fd-start25: probe whether the embedded Agave gets past clap parsing.

fd-start24 found the seccomp-kill fix (development.sandbox=false, fd-start24
dmesg showed no AUDIT_SECCOMP, metric tile came alive) but hit a NEW blocker:
the embedded Agave child printed clap usage and exited 1, with
  error: The following required arguments were not provided:
      --known-validator <VALIDATOR IDENTITY>...
Root cause: default.toml sets rpc.only_known=true, so agave_boot (run_agave.c:144)
emits --only-known-rpc. That clap arg has .requires("known_validators")
(rpc_bootstrap_config.rs:87), and our known_validators list is empty (bootstrap
dev node, no trusted peers). Fix: config-only [rpc] only_known=false (NOT a
source deviation), pushed via nbd-push.sh. This boot verifies the agave child
now proceeds past clap into its own initialization, and captures wherever it
stops next (likely genesis.bin load, since fdctl cannot create genesis — only
fddev can, which is not in the image).

Honest ceiling under TCG (x86_64-on-arm64, no KVM): `started` is the target.
`voting` is not expected (TCG is too slow to keep up with slots).
"""
import socket, subprocess, time, sys, os

SOCK = "/tmp/fd-vm/serial25.sock"
OUT  = "/tmp/fd-vm/console-start25.txt"
QEMU = "/opt/homebrew/bin/qemu-system-x86_64"
WAIT = 720  # 12 min — TCG boot (16 vCPU) + probe + 180s fdctl run + margin

try: os.unlink(SOCK)
except FileNotFoundError: pass

proc = subprocess.Popen(
    [QEMU,
     "-name", "fd-start25",
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
    stdout=open("/tmp/fd-vm/qemu-start25.log","w"),
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
        has_start = "===FD-START-PROBE-START===" in text
        last_line = text.strip().splitlines()[-1] if text.strip() else "(empty)"
        print(f"[t={int(now-(end-WAIT))}s] {len(buf)} bytes, start={has_start} summary={has_summary}, last: {last_line[:90]}", flush=True)
        last_print = now
        if has_summary:
            print("PROBE COMPLETE (SUMMARY seen) — draining 15 more seconds", flush=True)
            time.sleep(15)
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
    if any(k in stripped for k in ["nproc:", "MemTotal:", "configure init hugetlbfs exit",
                                    "configure init sysctl exit", "configure check all exit",
                                    "fdctl-run exit", "SUMMARY", "keys.c", "run.c",
                                    "ERR", "identity key", "fdctl run",
                                    "nr_hugepages(after", "mounts(after", "topob",
                                    "topology", "tile", "started", "agave", "genesis",
                                    "booting", "WARNING", "error:", "USAGE",
                                    "required arguments", "genesis.bin", "ledger",
                                    "vote", "slot", "PoH", "poh"]):
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
