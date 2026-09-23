import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";

assert.ok(process.argv.slice(2).every((arg) => arg === "--compose"), "Only --compose is supported");
const compose = process.argv.includes("--compose");
const composeArgs = ["compose", "-f", fileURLToPath(new URL("./compose.agave.yaml", import.meta.url))];

const enclave = "solana-local";
const expectedVersion = "4.3.0";
const expectedCommit = "825efd18292aff6ffcf9daa0f7612f21b3531a72";
const memoProgram = "Memo4c2pN8afCj432Lb7RMVKi9PbQnnW7ewFFaV3oAH";
const command = (binary, args, timeout = 30_000) =>
  execFileSync(binary, args, { encoding: "utf8", timeout }).trim();

function endpoint(service, port, protocol = "http") {
  if (compose) {
    const internalPorts = { rpc: 8899, ws: 8900, api: 3000, explorer: 3000 };
    const address = command("docker", [...composeArgs, "port", service, String(internalPorts[port])]);
    assert.match(address, /^127\.0\.0\.1:\d+$/);
    return `${protocol}://${address}`;
  }
  const number = command("kurtosis", ["port", "print", "--format", "number", enclave, service, port]);
  assert.match(number, /^\d+$/);
  return `${protocol}://127.0.0.1:${number}`;
}

async function jsonRequest(url, options = {}) {
  const response = await fetch(url, { ...options, signal: AbortSignal.timeout(15_000) });
  assert.equal(response.status, 200, `${url}: HTTP ${response.status}`);
  return response.json();
}

function slotNotification(url) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url);
    let done = false;
    const timer = setTimeout(() => finish(new Error("slotSubscribe timed out")), 15_000);
    function finish(error, slot) {
      if (done) return;
      done = true;
      clearTimeout(timer);
      socket.close();
      if (error) reject(error);
      else resolve(slot);
    }
    socket.onopen = () => socket.send(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "slotSubscribe" }));
    socket.onerror = () => finish(new Error("WebSocket connection failed"));
    socket.onmessage = ({ data }) => {
      try {
        const message = JSON.parse(data);
        if (message.error) throw new Error(JSON.stringify(message.error));
        if (message.method === "slotNotification") {
          const slot = message.params.result.slot;
          assert.ok(Number.isSafeInteger(slot) && slot > 0);
          finish(null, slot);
        }
      } catch (error) {
        finish(error);
      }
    };
  });
}

async function main() {
  const rpcUrl = endpoint("solana-validator", "rpc");
  const wsUrl = endpoint("solana-validator", "ws", "ws");
  const apiUrl = endpoint("solana-validator", "api");
  const explorerUrl = endpoint("solana-explorer", "explorer");
  const rpc = async (method, params = []) => {
    const body = await jsonRequest(rpcUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
    });
    assert.ok(!body.error, `${method}: ${JSON.stringify(body.error)}`);
    return body.result;
  };

  assert.equal(await rpc("getHealth"), "ok");
  const version = await rpc("getVersion");
  assert.equal(version["solana-core"], expectedVersion, "Unexpected Agave version");
  const genesisHash = await rpc("getGenesisHash");
  const startSlot = await rpc("getSlot", [{ commitment: "finalized" }]);
  assert.equal((await jsonRequest(`${apiUrl}/ping`)).message, "pong");
  const wsSlot = await slotNotification(wsUrl);

  const container = command("docker", [
    "ps", "-q", "--filter", compose ? "label=com.docker.compose.project=solana-agave43" : `label=kurtosis_enclave_name=${enclave}`,
    "--filter", compose ? "label=com.docker.compose.service=solana-validator" : "label=kurtosis_service_name=solana-validator",
  ]);
  assert.match(container, /^[a-f0-9]+$/, "Expected exactly one running validator");
  const containerInfo = JSON.parse(command("docker", ["inspect", container]))[0];
  const imageId = containerInfo.Image;
  if (compose) {
    assert.equal(containerInfo.HostConfig.Privileged, false);
    assert.equal(containerInfo.Config.User, "1000:1000");
    assert.deepEqual(containerInfo.HostConfig.CapDrop, ["ALL"]);
    assert.ok(containerInfo.HostConfig.SecurityOpt.some((option) => option.startsWith("no-new-privileges")));
    assert.ok(containerInfo.HostConfig.SecurityOpt.some((option) => option.startsWith("seccomp=") && !option.includes("unconfined")));
  }
  const imageInfo = JSON.parse(command("docker", ["image", "inspect", imageId]))[0];
  assert.equal(imageInfo.Os, "linux");
  assert.equal(imageInfo.Architecture, "arm64");
  assert.equal(imageInfo.Config.Labels["org.opencontainers.image.revision"], expectedCommit);
  const binaryVersion = command("docker", ["exec", container, "solana-test-validator", "--version"]);
  assert.ok(binaryVersion.includes(` ${expectedVersion} `), binaryVersion);
  assert.ok(binaryVersion.includes(`src:${expectedCommit.slice(0, 8)}`), binaryVersion);

  // Keys exist only in this local validator and are removed even on test failure.
  const transfer = JSON.parse(command("docker", ["exec", container, "bash", "-c", `
set -euo pipefail
keys=$(mktemp -d /tmp/solana-smoke.XXXXXX)
trap 'rm -r -- "$keys"' EXIT
umask 077
for name in sender recipient api_recipient; do
  solana-keygen new --no-bip39-passphrase --silent --outfile "$keys/$name.json" >/dev/null
done
recipient=$(solana --keypair "$keys/recipient.json" address)
api_recipient=$(solana --keypair "$keys/api_recipient.json" address)
solana --url http://127.0.0.1:8899 --keypair "$keys/sender.json" --commitment finalized airdrop 10 >/dev/null
transaction=$(solana --url http://127.0.0.1:8899 --keypair "$keys/sender.json" --commitment finalized transfer "$recipient" 1 --allow-unfunded-recipient --with-memo agave-4.3.0-arm64-smoke --output json-compact)
printf '{"recipient":"%s","apiRecipient":"%s","transaction":%s}\\n' "$recipient" "$api_recipient" "$transaction"
`], 180_000));
  const signature = transfer.transaction.signature;
  assert.equal(typeof signature, "string");
  let status;
  for (let attempt = 0; attempt < 30; attempt++) {
    status = (await rpc("getSignatureStatuses", [[signature], { searchTransactionHistory: true }])).value[0];
    if (status?.confirmationStatus === "finalized") break;
    await delay(1000);
  }
  assert.equal(status?.confirmationStatus, "finalized");
  assert.equal(status.err, null);
  const balance = await rpc("getBalance", [transfer.recipient, { commitment: "finalized" }]);
  assert.equal(balance.value, 1_000_000_000);
  const transaction = await rpc("getTransaction", [signature, { commitment: "finalized", maxSupportedTransactionVersion: 0 }]);
  assert.ok(transaction?.meta);
  assert.equal(transaction.meta.err, null);
  assert.ok(transaction.meta.logMessages?.includes(`Program ${memoProgram} success`), "SBF Memo did not execute successfully");
  const memoAccount = (await rpc("getAccountInfo", [memoProgram, { encoding: "base64", commitment: "finalized" }])).value;
  assert.equal(memoAccount?.executable, true);
  assert.equal(memoAccount.owner, "BPFLoaderUpgradeab1e11111111111111111111111");
  const apiFund = await jsonRequest(`${apiUrl}/fund`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ address: transfer.apiRecipient, amount: 1 }),
  });
  assert.equal(apiFund.message, "SOL airdrop successful");
  let apiBalance;
  for (let attempt = 0; attempt < 30; attempt++) {
    apiBalance = await rpc("getBalance", [transfer.apiRecipient, { commitment: "finalized" }]);
    if (apiBalance.value === 1_000_000_000) break;
    await delay(1000);
  }
  assert.equal(apiBalance.value, 1_000_000_000, "API airdrop did not finalize");
  const endSlot = await rpc("getSlot", [{ commitment: "finalized" }]);
  assert.ok(endSlot > startSlot, "Finalized slot did not advance");
  const explorerResponse = await fetch(explorerUrl, { signal: AbortSignal.timeout(15_000) });
  assert.equal(explorerResponse.status, 200);
  await explorerResponse.arrayBuffer();

  console.log(JSON.stringify({
    testedAt: new Date().toISOString(), backend: compose ? "compose" : "kurtosis",
    version, binaryVersion, imageId, privileged: containerInfo.HostConfig.Privileged,
    architecture: imageInfo.Architecture, sourceCommit: expectedCommit, genesisHash,
    rpcUrl, wsUrl, apiUrl,
    explorerUrl: `${explorerUrl}/?cluster=custom&customUrl=${encodeURIComponent(rpcUrl)}`,
    finalizedSlots: [startSlot, endSlot], wsSlot,
    signature, recipient: transfer.recipient, recipientLamports: balance.value,
    confirmationStatus: status.confirmationStatus, sbfMemoProgram: memoProgram,
    apiFundRecipient: transfer.apiRecipient, apiFundLamports: apiBalance.value,
  }, null, 2));
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
