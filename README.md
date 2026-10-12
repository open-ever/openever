# openever

Swift command-line tools for Everscale. Query lite servers over ADNL, prepare and decode TVM stacks, generate wallet keys, and send transfers from PreprocessedWalletV2 (PWV2) wallets.

```sh
openever --help
openever liteclient --help
openever wallet --help
openever wallet pwv2 send --help
```

## Connection configuration

Network commands read a JSON configuration file. Create an empty template, fill in your lite-server settings, then inspect the selected file:

```sh
openever config --create
openever config --create --out ./openever.json
openever config --path
openever config --read
```

`--create` prints this template to stdout without reading an existing configuration:

```json
{
  "liteclient": {
    "ip": "",
    "port": 0,
    "publicKey": ""
  }
}
```

Fill in all three fields before making network requests. `--create --out PATH` saves the template to a new file and refuses to overwrite an existing one. Omit `--out` or use `--out -` to print to stdout. Use exactly one of `--read`, `--create`, and `--path`; `--out` is available only with `--create`.

Example with fabricated server details and a public key placeholder:

```json
{
  "liteclient": {
    "ip": "192.0.2.10",
    "port": 3030,
    "publicKey": "<liteserver public key>"
  }
}
```

| Field | Value |
| --- | --- |
| `liteclient.ip` | Lite-server IP address or hostname. |
| `liteclient.port` | TCP port, 1–65535. |
| `liteclient.publicKey` | Server Ed25519 public key: base64 encoding of 32 bytes. |

Configuration paths are selected in this order:

1. `--config PATH`.
2. The case-sensitive `OPENEVER_CONFIG` environment variable, containing only a file path.
3. `./openever.json` in the current working directory.

`OPENEVER_CONFIG` is the only configuration environment variable. An unset or empty value uses `./openever.json`. Relative paths are resolved from the current working directory. If a path supplied through `--config` or `OPENEVER_CONFIG` does not exist, the command reports the missing file instead of falling back to another configuration.

`--path` prints the absolute path of the selected existing file. `--read` prints its contents as stored. Both report an error and exit with a nonzero status when no configuration file is found.

```sh
export OPENEVER_CONFIG=./network.json
openever config --path
openever config --read

# --config takes precedence over OPENEVER_CONFIG.
openever --config ./another-network.json config --path
openever config --read --config ./another-network.json
openever --config ./another-network.json liteclient account-state --account '0:ACCOUNT_HASH'
```

Individual connection options override the corresponding configuration fields:

```sh
openever liteclient account-state \
  --host lite.example.org \
  --port 3030 \
  --public-key SERVER_PUBLIC_KEY_BASE64 \
  --account '0:ACCOUNT_HASH'
```

Replace `ACCOUNT_HASH` and other uppercase placeholders with actual values. Raw account addresses use `workchain:64-hex-digits`, including `-1:...` for masterchain accounts.

Global configuration files containing a `liteservers` array are also supported as an alternative to the `liteclient` section. Select a server with the zero-based `--server-index` option:

```sh
openever --config global-config.json liteclient account-state \
  --server-index 1 --account '0:ACCOUNT_HASH'
```

`--config` can appear before or after subcommands. Connection options can appear after `liteclient` or `wallet pwv2`, or after their network operation. Connection and request timeouts default to 10 and 15 seconds; override them with `--connection-timeout` and `--request-timeout`.

## Lite-client commands

| Command | Purpose |
| --- | --- |
| `account-state` | Fetch account state and account/shard proofs. |
| `run-method` | Execute a getter with a serialized TVM parameter stack. |
| `send-message` | Submit a serialized message BOC. |
| `transaction` | Fetch one transaction at an explicit block and logical time. |
| `transactions` | Fetch transactions from a logical-time/hash cursor. |
| `lookup-block` | Resolve a full block identifier, including root and file hashes. |
| `query` | Send a raw boxed TL request and receive its boxed TL response. |
| `make-vm-params` | Serialize TVM parameters locally and print a base64 BOC. |
| `parse-vm-result` | Decode an old-format TVM result BOC locally into typed JSON. |

### Account state and block selection

`account-state` and `run-method` use the latest applied masterchain block by default. Use `--latest` explicitly or select a historical block with `--block`:

```sh
openever liteclient account-state --account '0:ACCOUNT_HASH' --latest
openever liteclient account-state --account '0:ACCOUNT_HASH' --block 12345
openever liteclient lookup-block --block 12345
```

Historical selection resolves block hashes through `liteServer.lookupBlock`. Supply both `--root-hash` and `--file-hash` to use a known full block ID without that lookup. Blocks default to workchain `-1` and shard `0x8000000000000000`; use `--block-workchain` and `--shard` for another workchain/shard. Explicit block options cannot be combined with `--latest`.

### Getters and TVM stacks

Generate an empty parameter tuple and pass its base64 BOC to a getter:

```sh
PARAMS=$(openever liteclient make-vm-params)
openever liteclient run-method \
  --account '0:ACCOUNT_HASH' \
  --method-name get_balance \
  --input-base64 "$PARAMS"
```

Use exactly one of `--method-name` or `--method-id`. A getter name resolves to `CRC16(name) | 0x10000`; numeric IDs accept signed decimal or `0x` hexadecimal values.

Parameter expressions are comma-separated. Quote the expression so the shell preserves parentheses:

```sh
openever liteclient make-vm-params 'n, i -1, t (i 23, n)'
openever liteclient parse-vm-result --input-base64 "$PARAMS"
openever liteclient parse-vm-result --input-file result.boc
```

| Type | Expression |
| --- | --- |
| None | `n` or `none` |
| Integer | `i -1` or `integer -1` |
| Builder | `b BOC_BASE64` or `builder BOC_BASE64` |
| Cell | `c BOC_BASE64` or `cell BOC_BASE64` |
| Slice | `s BOC_BASE64` or `slice BOC_BASE64` |
| Tuple | `t (i 23, n)` or `tuple (integer 23, none)` |

Integers support the signed 257-bit range. Tuples may be nested and contain up to 255 items each. Builder, cell, and slice inputs must contain exactly one BOC root. Continuations are unsupported.

`parse-vm-result` also accepts base64 as a positional argument. Its JSON preserves integers as decimal strings, decodes tuples recursively, and includes BOCs for cells and builders. Slice values include the backing cell BOC and bit/reference ranges with exclusive end offsets.

`run-method` requests the result stack by default. Add `--account-proofs`, `--state-proof`, `--initial-context`, or `--library-extras` to request additional fields; `--no-result` omits the result stack. `--empty-params` sends zero parameter bytes for servers supporting that form and cannot be combined with `--input-*`.

### Transactions

```sh
openever liteclient transaction \
  --account '0:ACCOUNT_HASH' --block 12345 --lt 1000000000

openever liteclient transactions \
  --account '0:ACCOUNT_HASH' \
  --lt 1000000000 --hash TRANSACTION_HASH --count 10
```

`transaction` requires an explicit block. `transactions` requires both the logical time and hash of its starting transaction; `--count` defaults to 10. Logical times accept unsigned 64-bit decimal or hexadecimal values. Hashes accept 64 hexadecimal digits or base64.

### Messages and raw queries

```sh
openever liteclient send-message --input-file message.boc
openever liteclient query --input-file request.tl --binary-encoding hex
```

A raw query must include the lite-server request constructor ID, without ADNL or `liteServer.query` envelopes. Its byte length must be divisible by four. Responses include the constructor ID and encoded response bytes.

## Wallet commands

### Generate a seed, keys, and address

These commands run locally without a lite-server connection:

```sh
openever wallet seed --count 24 --out seed.txt
openever wallet keys --seed-file seed.txt --out keys.json
openever wallet pwv2 address --keys-file keys.json --out address.txt
```

`wallet seed` generates an English BIP39 mnemonic with 12 words by default, or 24 with `--count 24`. Keys use the Everscale derivation path `m/44'/396'/0'/0/0`.

`wallet keys` accepts `--seed` or `--seed-file`. Without seed input, it generates a new 12-word mnemonic internally and outputs only the keys. Generate the seed separately as above when you want to retain the mnemonic.

Keys JSON uses the exact field names `privatKey` and `publicKey`, each containing a 32-byte hexadecimal value:

```json
{
  "privatKey": "PRIVATE_KEY_HEX",
  "publicKey": "PUBLIC_KEY_HEX"
}
```

Address derivation and transfers require exactly one credential source: `--keys`, `--keys-file`, `--seed`, or `--seed-file`. Address derivation also accepts keys JSON containing only `publicKey`. The wallet workchain defaults to `0`; set it with `--workchain` or `-w`.

Seed and address output is plain text; key output is JSON. `--out` creates a new file and refuses to overwrite an existing one. Seed and key files are created with owner-only permissions. Omit `--out` or use `--out -` to write to stdout.

### Balance and transfers

```sh
openever wallet pwv2 balance --account '0:ACCOUNT_HASH'

openever wallet pwv2 send \
  --keys-file keys.json \
  --dest '0:DESTINATION_HASH' \
  --ever 1.25
```

Balance output includes `nanoEver`, `ever`, and account status: `nonexistent`, `uninitialized`, `active`, or `frozen`.

Transfers derive the source wallet from its keys and workchain, fetch its state and sequence number, then sign and submit one outgoing message. Fund the derived address first; a funded, uninitialized wallet is deployed automatically with its first transfer.

Use exactly one of `--ever` and `--nanoEver` (`--nano-ever` is an alias). One EVER equals 1,000,000,000 nanoEVER. EVER amounts accept a dot or comma decimal separator with up to nine fractional digits.

Wallet balance and destination addresses accept raw `workchain:hex`, base64, or base64url friendly addresses. The bounce flag follows a friendly destination address and defaults to false for raw addresses; override it with `--bounce` or `--no-bounce`.

`--flag` sets the TVM send mode, defaulting to `3` (pay fees separately and ignore action errors). `--ttl` sets the message lifetime, defaulting to 60 seconds, with a range of 1–3600 seconds.

Supply a destination body or StateInit as a base64 BOC:

```sh
openever wallet pwv2 send \
  --seed-file seed.txt \
  --dest '0:DESTINATION_HASH' \
  --nanoEver 1000000000 \
  --body-file body.boc.base64 \
  --state-init-file state-init.boc.base64
```

`--body-file` and `--state-init-file` read UTF-8 base64 text. Inline alternatives are `--body` and `--state-init`. Each BOC must contain one ordinary root cell. The supplied StateInit belongs to the destination contract.

Transfer output includes the source and destination, amount in nanoEVER, sequence number, message hash, expiration time, and server acceptance status. Acceptance by the lite server does not confirm a blockchain transaction.

## Input, output, and exit status

Lite-client binary input uses exactly one of:

- `--input-file PATH`: raw binary bytes; `-` reads stdin.
- `--input-base64 VALUE`: base64 or base64url text.
- `--input-hex VALUE`: hexadecimal text with an optional `0x` prefix.

Wallet seed, keys, body, and StateInit file inputs also accept `-` for stdin. Only one input file in a transfer can read stdin.

Query results, balances, transfers, and decoded TVM values are JSON on stdout. JSON is pretty-printed by default; `--compact` produces a single line. Binary fields use base64 by default; `--binary-encoding hex` switches them to hexadecimal. Each binary field contains `encoding`, `byteCount`, and `data`. Logical times, method IDs, wallet amounts in nanoEVER, and decoded TVM integers are strings to preserve numeric precision.

Errors go to stderr and produce a nonzero exit status. Getter VM exit codes `0` and `1` are successful; other VM exit codes print the response JSON before exiting with status `1`. Message submission status `1` means accepted; other statuses print the response JSON and exit with status `1`.
