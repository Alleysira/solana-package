# Solana Kurtosis Package

A Kurtosis package for running a local Solana environment with test validator and block explorer.

> [!IMPORTANT]
> The original package below still launches one `solana-test-validator`. The
> pinned five-client investigation and the honest acceptance boundary are in
> [`clients.lock.json`](clients.lock.json) and [`MULTICLIENT.md`](MULTICLIENT.md).
> A five-node latest-stable network cannot currently be claimed because Sig's
> stable release has no validator and Solana Labs 1.18 is incompatible with the
> current 4.3 genesis/vote-account format.

## Usage

To run the package with default settings:

```bash
kurtosis run --enclave test .
```

To run with custom parameters:

```bash
kurtosis run --enclave test . --args-file sample_params.yaml
```

To shut down the enclave:

```bash
kurtosis clean -a
```

## Configuration

You can customize the package by providing a YAML file with parameters:

### Validator Parameters

- `image`: Docker image for the Solana test validator
- `clone_tokens`: Whether to clone token program accounts
- `clone_defi`: Whether to clone DeFi protocol accounts
- `clone_layer_zero`: Whether to clone LayerZero contracts
- `rpc_port`: Port for RPC endpoint
- `ws_port`: Port for WebSocket endpoint
- `additional_accounts`: Additional accounts to clone
- `ledger_compaction_interval`: Ledger compaction interval
- `log_level`: Log level (info, warn, error, debug, trace)
- `extra_args`: Extra arguments to pass to solana-test-validator

### Explorer Parameters

- `enabled`: Whether to enable the block explorer
- `image`: Docker image for the explorer
- `explorer_port`: Port for the explorer UI

See `sample_params.yaml` for a complete example.
