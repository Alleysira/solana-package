# Firedancer host deployment boundary

Firedancer 26.09.4 is deliberately kept outside the local Docker/Kurtosis
enclave. Its XDP networking, huge pages, CPU topology, startup privileges, and
reported ~109 GiB testnet memory footprint require a dedicated Linux host. The
preflight defaults to 128 GiB physical RAM to leave operating-system headroom.
Pretending this is an ordinary unprivileged container would make the deployment
template misleading.

## Build host

Use the exact source commit in `clients.lock.json`, including submodules:

```bash
git -C ../firedancer submodule update --init --recursive
./preflight-firedancer.sh build ../firedancer
```

Then follow the pinned release build instructions. A generic x86_64 build is
preferred over a native build when the build and validator hosts differ:

```bash
cd ../firedancer
FD_AUTO_INSTALL_PACKAGES=1 ./deps.sh fetch check install
source activate MACHINE=linux_gcc_x86_64
make -j8 firedancer
```

Record `./build/firedancer version` and the SHA-256 of the resulting binary
before copying it to the validator host. Do not claim Firedancer acceptance
from a successful compile alone.

## Validator host

1. Create a dedicated, unprivileged runtime user. The systemd unit starts as
   root because Firedancer needs privileged initialization, then Firedancer
   itself switches to the user in the TOML configuration.
2. Copy and render `config.toml.template`. Give this node its own identity and
   vote account, but use the exact shared `genesis.bin`, genesis hash, and shred
   version created for the Agave/Jito network.
3. Check resources and networking:

   ```bash
   sudo FIREDANCER_INTERFACE=eth0 ./preflight-firedancer.sh run ../firedancer
   ```

4. Review the permanent host changes, then initialize them once:

   ```bash
   sudo /opt/firedancer/firedancer configure init all --config /etc/firedancer/config.toml
   ```

5. Render `firedancer.service.template`, install it in systemd, and start it.

The service's `configure check all` is read-only. The earlier `configure init`
is intentionally not automated because upstream warns that it makes permanent
host changes.

Acceptance requires the node to appear in gossip and vote-account RPC output,
advance/root slots with Agave and Jito, and remain on the shared genesis hash.
The final network smoke test must also submit and finalize a transfer while all
three validators are live.
