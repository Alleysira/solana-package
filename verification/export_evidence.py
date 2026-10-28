#!/usr/bin/env python3
"""Export only this enclave's logs and public verification artifacts."""
import argparse
import datetime
import gzip
import json
from pathlib import Path
import subprocess
p = argparse.ArgumentParser()
p.add_argument("--enclave", required=True)
p.add_argument("--out", required=True)
args = p.parse_args()
out = Path(args.out)
out.mkdir(parents=True, exist_ok=True)

def docker(*parts, check=True):
    result = subprocess.run(["sudo", "-n", "docker", *parts], capture_output=True)
    if check and result.returncode:
        raise RuntimeError(result.stderr.decode(errors="replace"))
    return result

def zipped(name, data):
    with gzip.open(out / name, "wb") as f:
        f.write(data)

manifest = {"capturedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "enclave": args.enclave, "services": {}, "host": {}, "sourceCommits": {}}
for key, cmd in [("kernel", ["uname", "-a"]), ("memory", ["free", "-b"]),
                 ("disk", ["df", "-B1", "/"]), ("cpu", ["lscpu"]),
                 ("docker", ["sudo", "-n", "docker", "version"]),
                 ("kurtosis", ["sudo", "-n", "kurtosis", "version"])]:
    result = subprocess.run(cmd, capture_output=True, text=True)
    manifest["host"][key] = result.stdout
for name in [".", "firedancer", "agave", "jito-solana", "sig", "solana-package"]:
    repo = Path(__file__).resolve().parents[2] / name
    manifest["sourceCommits"][name] = subprocess.check_output(
        ["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
for cid in docker("ps", "-aq").stdout.decode().splitlines():
    info = json.loads(docker("inspect", cid).stdout)[0]
    if "kt-" + args.enclave not in info["NetworkSettings"]["Networks"]:
        continue
    name = info["Name"].lstrip("/")
    role = name.split("--")[0]
    if role not in ["val-bootstrap", "val-joiner", "val-firedancer", "sig-observer", "network-verifier"]:
        continue
    record = {"container": name, "imageId": info["Image"], "imageTag": info["Config"]["Image"],
              "state": info["State"], "ports": info["NetworkSettings"]["Ports"],
              "networks": info["NetworkSettings"]["Networks"]}
    manifest["services"][role] = record
    logs = docker("logs", cid, check=False)
    zipped(role + "-container.log.gz", logs.stdout + logs.stderr)
    if not info["State"]["Running"]:
        continue
    if role == "val-firedancer":
        files = docker("exec", cid, "bash", "-c", "ls -1 /tmp/fd-0.1.1_*", check=False).stdout.decode().splitlines()
        for i, path in enumerate(files):
            zipped(f"firedancer-internal-{i}.log.gz", docker("exec", cid, "cat", path).stdout)
        (out / "firedancer.toml").write_bytes(docker("exec", cid, "cat", "/tmp/firedancer.toml").stdout)
        record["binaryVersion"] = docker("exec", cid, "firedancer", "version").stdout.decode().strip()
        record["buildInfo"] = docker("exec", cid, "cat", "/opt/firedancer/BUILD-INFO").stdout.decode()
    elif role == "sig-observer":
        zipped("sig.log.gz", docker("exec", cid, "cat", "/var/lib/sig/sig.log", check=False).stdout)
        (out / "sig-config.zon").write_bytes(docker("exec", cid, "cat", "/var/lib/sig/config.zon").stdout)
        record["buildInfo"] = docker("exec", cid, "cat", "/opt/sig/BUILD-INFO").stdout.decode()
        record["actualProcessAlive"] = docker(
            "exec", cid, "bash", "-c", 'kill -0 "$(cat /var/lib/sig/sig.pid)"', check=False).returncode == 0
    elif role in ["val-bootstrap", "val-joiner"]:
        binary = "/opt/jito/bin/agave-validator" if role == "val-bootstrap" else "/opt/agave/bin/agave-validator"
        record["binaryVersion"] = docker("exec", cid, binary, "--version").stdout.decode().strip()
        (out / "meta.env").write_bytes(docker("exec", cid, "cat", "/data/meta.env").stdout)
    else:
        paths = docker("exec", cid, "python3", "-c",
                       "import pathlib,json; print(json.dumps([p.name for p in pathlib.Path('/data/verification').glob('*') if p.is_file()]))",
                       check=False)
        if paths.returncode == 0:
            destination = out / "verification"
            destination.mkdir(exist_ok=True)
            for filename in json.loads(paths.stdout):
                if "keypair" in filename:
                    continue
                (destination / filename).write_bytes(
                    docker("exec", cid, "cat", "/data/verification/" + filename).stdout)
(out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(out)
