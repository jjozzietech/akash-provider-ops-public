# // anti-mining

Two scripts that detect and evict crypto miners from an Akash provider cluster. Both auto-blacklist the tenant and re-inject the updated list into the running provider via `helm upgrade --reuse-values` with dynamic chart version detection.

Sanitized from production. Real detection patterns. Placeholders for anything site-specific.

## // the model

Two detection vectors, both acting on match:

**`evict-miners.sh`** — pattern-based, cheap, runs every 5 minutes.

Iterates active tenant namespaces. Matches on pod names or container images against curated keyword lists. Catches self-identifying miners — the ones running xmrig, the ones with "miner" in the deployment name.

**`check-cpu-miners.sh`** — behavioural, expensive, runs every 10 minutes.

SSHs into each worker node, reads `/proc/loadavg`. If load exceeds threshold, walks the top CPU processes and extracts `AKASH_OWNER` from each process's environment. Catches hidden miners — the ones running under `python3 main.py` or `groundstate --mine` that patterns miss.

Both scripts feed the same outcome: close leases, delete namespaces, append the tenant address to your bid script's `BLACKLIST` array, and fire a `helm upgrade` with the new blacklist injected into `bidpricescript`. Same helm-upgrade sequence in both — dynamic chart version detection prevents the version-drift regression that hardcoded chart references used to cause.

Companion state lives in your bid pricing script (referenced here as `<PROVIDER_BID_SCRIPT_PATH>`). That script must contain a bash `BLACKLIST=( ... )` array. Both scripts here `sed`-append to it in place.

## // what's in here

| File | What it does | Cron |
|---|---|---|
| [`evict-miners.sh`](./evict-miners.sh) | Pattern-based detection: pod-name and image keywords | `*/5 * * * *` |
| [`check-cpu-miners.sh`](./check-cpu-miners.sh) | Behavioural detection: load-average + `AKASH_OWNER` inspection | `*/10 * * * *` |

Log location for both: `/var/log/miner-eviction.log`.

## // placeholders to replace

Before running either script, substitute:

| Placeholder | What it is |
|---|---|
| `<YOUR_PROVIDER_WALLET_ADDRESS>` | Your provider's on-chain address, used as `--from` in `provider-services tx market lease close` |
| `<PROVIDER_BID_SCRIPT_PATH>` | Path to your bid pricing script (must contain a `BLACKLIST=( ... )` bash array) |

Grep both scripts for `<` to find every occurrence.

## // detection patterns

`evict-miners.sh` matches on two keyword lists:

- **`IMAGE_KEYWORDS`** — substrings that catch known miner container images
- **`NAME_KEYWORDS`** — substrings that catch pod names containing miner-related words

Both lists are opinionated based on 6+ months of observed tenant abuse patterns. Neither is exhaustive — new miner brands appear, old ones disappear. Consider both as starting points to tune against your own tenant mix.

## // false positive warnings

**Both scripts are aggressive.** They act on match, no confirmation loop.

`evict-miners.sh` can false-positive on:
- Legitimate workloads with "miner" in the name (data-mining containers, log-mining tools)
- Base images that happen to contain a keyword string in an unrelated layer

`check-cpu-miners.sh` can false-positive on:
- Legitimate high-CPU workloads (ML training, video encoding, scientific compute)
- Sustained crypto workloads that ARE legitimate rentals (some tenants deliberately rent for GPU mining and pay accordingly — whether you accept those is your provider policy)

**Before enabling either script via cron, run them manually and inspect the log.** Both write full detail of what they would evict. Confirm the false-positive rate is acceptable for your tenant mix.

## // companion blacklist repo (planned)

The 40+ tenant addresses currently blacklisted on this operator's setup will be published separately as `akash-miner-blacklist` — a dedicated community resource with issue templates for miner reports. Once live, this section links to it as a reference dataset operators can pull from.

The scripts here are deliberately generic: they work with whatever blacklist you populate. The blacklist repo is where the shared community intelligence will live.

## // helm-upgrade sequence — worth reading

Both scripts trigger `helm upgrade akash-provider akash/provider --reuse-values` after blacklist changes. Two details are non-obvious and worth calling out:

1. **Dynamic chart version detection.** An earlier iteration of these scripts hardcoded `--version 16.0.0`. That was fine until the chart bumped, at which point every eviction silently downgraded the provider chart. The `helm list -o json | python3 ...` inline reads the currently-running chart version and passes it explicitly. Prevents the drift entirely.

2. **Liveness probe patch.** After each `helm upgrade`, the provider StatefulSet gets patched to remove the container's liveness probe. On the running provider setup this script was extracted from, the probe was too aggressive at `failureThreshold=1` for the inventory-operator sidecar, causing needless pod restarts. Your setup may or may not need this — check whether removing the patch causes probe failures in your logs before adopting.

## // use in production

- Test both scripts manually before enabling via cron
- Watch `/var/log/miner-eviction.log` for the first few days
- Tune `CPU_THRESHOLD` in `check-cpu-miners.sh` for your node sizing (default 20 is for 16-24 core workers)
- Tune the keyword lists in `evict-miners.sh` for your observed tenant patterns
- Verify passwordless root SSH from your control host to all workers before enabling `check-cpu-miners.sh`

## // license

MIT — see LICENSE in repo root.
