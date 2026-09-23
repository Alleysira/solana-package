# Agave io_uring Profile

Source: https://github.com/moby/profiles/blob/seccomp/v0.1.0/seccomp/default.json

Docker Engine 28.5.2 pins `github.com/moby/profiles/seccomp v0.1.0` in
`vendor/modules.txt`. `agave.json` retains that profile's default-deny policy
and existing rules, adding one allow rule for exactly these syscalls:

- `io_uring_setup`
- `io_uring_enter`
- `io_uring_register`

The source profile is Apache-2.0 licensed; see `LICENSE`.
Enabling io_uring exposes additional kernel attack surface. Use an updated
kernel and trusted local test workloads; this is not a security certification.

On OrbStack / Docker 28.5.2, `probe-io-uring.c` returned `EPERM` with the default
profile, including when only `SYS_ADMIN` was added. This profile passed with
UID/GID 1000, all capabilities dropped, and `no-new-privileges` enabled.
The probe returned feature bits `0x3ffff`, including the two features checked by
Agave (`IORING_FEAT_NODROP` and `IORING_FEAT_SQPOLL_NONFIXED`).

Kurtosis 1.20.0 does not expose per-service custom seccomp profiles. Do not
silently replace this profile with `privileged: true` or a global daemon change.
