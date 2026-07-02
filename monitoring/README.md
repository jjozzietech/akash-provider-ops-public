# // monitoring

Scripts that watch the provider from outside and act when something's stuck.

## What's here

| Script | Purpose | Destructive? |
|---|---|---|
| [`check-provider-bids.sh`](./check-provider-bids.sh) | Detects a stuck provider pod and restarts it | Yes — deletes the provider pod when triggered |

## check-provider-bids.sh

### The problem it solves

The Akash provider pod occasionally gets stuck in a state where it logs a
flood of `incorrect account sequence` errors but stops completing bids.
The pod is running from Kubernetes' perspective — liveness probes pass,
no crashes — but it isn't earning. Manual pod restart clears it.

This script automates that detection and recovery.

### How it decides

Two signals from the provider container logs:

- **`bid complete`** count over the last 30 minutes — proxy for "provider is working"
- **`incorrect account sequence`** count over the last 10 minutes — proxy for "provider is stuck"

Restart triggers when sequence errors exceed the threshold AND bid completions
are zero. Either signal alone is inconclusive; both together are the fingerprint
of a stuck pod.

A grace period prevents restart loops immediately after deployment or upgrade.

### How to run it

Cron every 5–10 minutes on the control plane node (or wherever `kubectl` is
authenticated against the cluster):
