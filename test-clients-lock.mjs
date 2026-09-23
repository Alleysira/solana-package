import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = dirname(fileURLToPath(import.meta.url));
const lock = JSON.parse(readFileSync(join(root, "clients.lock.json"), "utf8"));

test("lock contains exactly the five documented client families", () => {
  assert.deepEqual(
    lock.clients.map(({ id }) => id).sort(),
    ["agave", "firedancer", "jito-solana", "sig", "solana-labs"],
  );
  assert.equal(new Set(lock.clients.map(({ id }) => id)).size, 5);
});

test("every release is immutable and traceable", () => {
  for (const client of lock.clients) {
    assert.match(client.release.tag, /^v/);
    assert.match(client.release.commit, /^[0-9a-f]{40}$/);
    assert.equal(new URL(client.release.url).hostname, "github.com");
    assert.ok(!Number.isNaN(Date.parse(client.release.publishedAt)));
  }
});

test("acceptance count follows capability and compatibility data", () => {
  const candidates = lock.clients
    .filter(({ stableReleaseCanVote, targetNetwork }) =>
      stableReleaseCanVote && targetNetwork?.startsWith("generation-4.3"))
    .map(({ id }) => id)
    .sort();
  assert.deepEqual(candidates, [...lock.acceptance.compatibleCandidateSet].sort());
  assert.equal(lock.acceptance.currentlyFeasibleLatestStableVotingClients, candidates.length);
  assert.equal(lock.acceptance.result, "not-achievable-with-all-five-latest-stable-releases");
});

test("Sig stable is never counted as a validator", () => {
  const sig = lock.clients.find(({ id }) => id === "sig");
  assert.equal(sig.implementation, "rpc-library");
  assert.equal(sig.stableReleaseCanVote, false);
});
