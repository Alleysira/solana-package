import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, readFileSync, existsSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const script = join(dirname(fileURLToPath(import.meta.url)), "build-agave.sh");

function run(overrides = {}) {
  const directory = mkdtempSync(join(tmpdir(), "agave-build-guards-"));
  const marker = join(directory, "docker-called");
  const counter = join(directory, "df-count");
  const mock = (name, body) => writeFileSync(join(directory, name), `#!/bin/sh\n${body}\n`, { mode: 0o755 });
  mock("git", 'case "$*" in *rev-parse*) echo 825efd18292aff6ffcf9daa0f7612f21b3531a72 ;; *status*) printf "%s" "$MOCK_DIRTY" ;; esac');
  mock("df", `
n=0
if [ -f "$MOCK_COUNTER" ]; then n=$(cat "$MOCK_COUNTER"); fi
n=$((n + 1))
printf '%s' "$n" > "$MOCK_COUNTER"
free=25000000
case "$MOCK_DISK" in low) free=1000000 ;; falls) if [ "$n" -gt 1 ]; then free=1000000; fi ;; esac
printf 'Filesystem 1024-blocks Used Available Capacity Mounted\\nmock 30000000 1 %s 1%% /\\n' "$free"
`);
  mock("docker", `
printf '%s\\n' "$*" > "$MOCK_MARKER"
if [ "$MOCK_HOLD" = 1 ]; then
  trap 'exit 143' TERM
  while :; do /bin/sleep 0.1; done
fi
exit "$MOCK_EXIT"
`);
  mock("sleep", "exec /bin/sleep 0.1");
  let status = 0;
  let output = "";
  let result;
  try {
    output = execFileSync("/bin/bash", [script], {
      encoding: "utf8", timeout: 10_000,
      env: {
        ...process.env, PATH: `${directory}:/usr/bin:/bin`, BUILD_CA_PEM: "",
        BUILD_JOBS: "2", BUILD_DISK_FLOOR_GIB: "3", MOCK_DIRTY: "", MOCK_EXIT: "0",
        MOCK_MARKER: marker, MOCK_COUNTER: counter, ...overrides,
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
  } catch (error) {
    assert.notEqual(error.code, "ETIMEDOUT", "Guard failed to stop promptly");
    status = error.status;
    output = `${error.stdout ?? ""}${error.stderr ?? ""}`;
  } finally {
    const called = existsSync(marker);
    const args = called ? readFileSync(marker, "utf8") : "";
    rmSync(directory, { recursive: true });
    result = { status, output, called, args };
  }
  return result;
}

test("invalid numeric configuration never invokes Docker", () => {
  const result = run({ BUILD_JOBS: "invalid" });
  assert.equal(result.status, 1);
  assert.equal(result.called, false);
});

test("low starting disk space never invokes Docker", () => {
  const result = run({ MOCK_DISK: "low" });
  assert.equal(result.status, 1);
  assert.equal(result.called, false);
});

test("modified source is rejected before Docker", () => {
  const result = run({ MOCK_DIRTY: " M Cargo.toml" });
  assert.equal(result.status, 1);
  assert.equal(result.called, false);
});

test("empty optional secret works with macOS Bash 3.2", () => {
  const result = run();
  assert.equal(result.status, 0, result.output);
  assert.equal(result.called, true);
  assert.match(result.args, /--platform linux\/arm64/);
  assert.doesNotMatch(result.args, /--secret/);
});

test("Docker failure is propagated", () => {
  assert.equal(run({ MOCK_EXIT: "7" }).status, 7);
});

test("disk floor reached during a build cancels promptly", () => {
  const result = run({ MOCK_DISK: "falls", MOCK_HOLD: "1" });
  assert.equal(result.status, 2, result.output);
  assert.match(result.output, /Disk safety floor reached/);
});
