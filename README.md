# // akash-provider-ops-public

Sanitized operational artefacts from a production [Akash Network](https://akash.network) provider running in the `au-syd` region.

Real scripts, real thresholds, adapted from months of running one.

## // why this exists

Most public writing about Akash providers is either the official onboarding guide or a first-week "I stood one up" post. There's very little material about what happens after month three — when miners have found you, the chain has upgraded twice, a helm chart has regressed, and a disk has failed.

This repo publishes the scripts and notes that came out of running one provider through those months, sanitized so they can be adapted for other setups. Nothing here is turnkey. Everything here has been on production for at least a quarter.

Longer-form context lives on the operator's [`/log`](https://jjozzietech.com.au/log) — each script here will eventually pair with a post explaining what problem it solves and why the solution looks the way it does.

## // what's in here

| Directory | What's inside |
|---|---|
| [`monitoring/`](./monitoring) | Health checks and self-heal scripts that watch the provider from outside |

More directories will land as they get sanitized:

- `anti-mining/` — three-layer defense against tenant abuse of GPU compute
- `backups/` — etcd and provider-state backup scripts
- `docs/` — runbooks for helm upgrade post-sequence, ghost-lease cleanup

## // what's NOT here and why

- **No wallet keys or provider secrets.** These never appear in operational scripts; they live in Kubernetes secrets and (for cold storage) on hardware wallets.
- **No internal IPs, subnets, or hostnames.** Placeholders where they'd normally appear. Adopt for your own network.
- **No specific tenant addresses.** A community-maintained blacklist repo is coming in a later phase.
- **No helm values files.** These contain per-provider addressing and pricing; sharing them dilutes their signal.
- **No pricing scripts.** Bid pricing is a lever, not a formula. Publishing our numbers would be misleading — read the `/log` posts on pricing philosophy instead.

## // use at your own risk

These are reference implementations from one specific setup: Ubuntu on Proxmox, kubeadm-built Kubernetes with kube-vip HA control plane, Ceph via Rook, NGINX Gateway Fabric ingress. Some scripts assume `kubectl` is authenticated against the local cluster; others assume a specific log file path.

Read the header comment of every script before running it. Every script that changes cluster state respects a `DRY_RUN=true` flag; use it on the first run.

PRs welcome — especially for:
- Portability improvements (different distros, different ingress, non-Ceph storage)
- Additional detection signals or thresholds that worked for your setup
- Documentation clarifications

## // the operator

Sole operator: jjozzietech, based in Sydney AU.

- Website — [jjozzietech.com.au](https://jjozzietech.com.au) — log, stack, validators
- Akash provider address — `akash1sev...wd4e` (au-syd region)
- GitHub — [github.com/jjozzietech](https://github.com/jjozzietech)
- X — [@jjozzietech](https://x.com/jjozzietech)
- Discord — `jjozzietech` in the Akash Network server

## // license

MIT — see [LICENSE](./LICENSE). Adapt freely. Attribution appreciated but not required.
