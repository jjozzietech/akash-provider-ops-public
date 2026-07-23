#!/bin/bash
#
# evict-miners.sh — pattern-based miner detection + eviction + auto-blacklist
#
# What it does:
#   Every 5 minutes (via cron), scans tenant namespaces for pod names OR
#   container images matching known miner patterns. On match:
#     1. Closes the lease via `provider-services tx market lease close`
#     2. Force-deletes the namespace
#     3. Appends the tenant address to your bid script's BLACKLIST array
#     4. Re-runs `helm upgrade` with the updated blacklist injected
#
# Placeholders (replace before use):
#   <YOUR_PROVIDER_WALLET_ADDRESS>  — your provider's on-chain address
#   <PROVIDER_BID_SCRIPT_PATH>       — path to your bid pricing script,
#                                      which must contain a BLACKLIST=( ... )
#                                      bash array. See project README for
#                                      the companion script structure.
#
# Suggested cron entry (edit with `crontab -e`):
#   */5 * * * * /usr/local/bin/evict-miners.sh
#
# Log location: /var/log/miner-eviction.log
#
# WARNING — false positive risk:
#   The keyword lists below will match legitimate workloads whose names
#   include words like "miner" (e.g. data-mining containers) or use base
#   images with those tokens. Run `check-cpu-miners.sh` for a couple of
#   days first to sanity-check what would be evicted, before enabling
#   this via cron. Consider narrowing the patterns to your observed
#   tenant mix.
#
# License: MIT — see LICENSE in repo root.
#

export PATH=/usr/local/bin:/usr/bin:/bin:$PATH
PROVIDER="<YOUR_PROVIDER_WALLET_ADDRESS>"
IMAGE_KEYWORDS="xmrig|akash-xmrig|cryptoandcoffee|gitworker|groundstate77|malik8662|openclaw|zjuuu"
NAME_KEYWORDS="miner|xmrig|monero|nicehash|fennec|veil|cgminer|gminer|lolminer|bzminer|ethminer|phoenixminer|nanominer"
PRICE_SCRIPT="<PROVIDER_BID_SCRIPT_PATH>"

ACTIVE_NS=$(kubectl get namespaces --no-headers 2>/dev/null | grep "Active" | \
  grep -v "kube-system\|rook-ceph\|akash-services\|cert-manager\|ingress\|local-path\|gpu-operator\|calico\|monitoring\|default" | \
  awk '{print $1}')

MINERS=""
for ns in $ACTIVE_NS; do
  POD_NAMES=$(kubectl get pods -n $ns --no-headers 2>/dev/null | awk '{print $1}')
  if echo "$POD_NAMES" | grep -qiE "$NAME_KEYWORDS"; then
    MINERS="$MINERS $ns"; continue
  fi
  IMAGES=$(kubectl get pods -n $ns -o jsonpath='{.items[*].spec.containers[*].image}' 2>/dev/null)
  if echo "$IMAGES" | grep -qiE "$IMAGE_KEYWORDS"; then
    MINERS="$MINERS $ns"
  fi
done

MINERS=$(echo "$MINERS" | tr ' ' '\n' | sort -u | grep -v "^$")
if [ -z "$MINERS" ]; then exit 0; fi

echo "$(date): Miners detected! Evicting..." >> /var/log/miner-eviction.log
HELM_UPGRADE_NEEDED=false

for ns in $MINERS; do
  OWNER=$(kubectl get namespace $ns -o yaml 2>/dev/null | grep "lease.id.owner" | awk '{print $2}')
  DSEQ=$(kubectl get namespace $ns -o yaml 2>/dev/null | grep "lease.id.dseq" | awk '{print $2}' | tr -d '"')
  if [ -z "$OWNER" ] || [ -z "$DSEQ" ]; then continue; fi
  echo "$(date): Closing $OWNER/$DSEQ" >> /var/log/miner-eviction.log
  provider-services tx market lease close \
    --owner $OWNER --dseq $DSEQ --gseq 1 --oseq 1 \
    --node https://rpc.akashnet.net:443 \
    --from $PROVIDER \
    --keyring-backend test --chain-id akashnet-2 --yes 2>/dev/null
  kubectl delete namespace $ns --force --grace-period=0 2>/dev/null &
  if ! grep -q "$OWNER" "$PRICE_SCRIPT"; then
    echo "$(date): Auto-blacklisting $OWNER" >> /var/log/miner-eviction.log
    sed -i "s/BLACKLIST=(/BLACKLIST=(\n  \"$OWNER\"/" "$PRICE_SCRIPT"
    HELM_UPGRADE_NEEDED=true
  fi
  sleep 2
done

if [ "$HELM_UPGRADE_NEEDED" = true ]; then
  echo "$(date): Updating helm with new blacklist..." >> /var/log/miner-eviction.log
  PRICE_SCRIPT_B64=$(base64 -w 0 "$PRICE_SCRIPT")

  # Auto-detect current chart version — prevents accidental up/downgrade.
  # An earlier version of this script hardcoded chart 16.0.0, which caused
  # silent downgrades after chart bumps. Dynamic detection eliminated that.
  CURRENT_CHART=$(helm list -n akash-services --output json 2>/dev/null | python3 -c "
import sys, json
try:
    for r in json.load(sys.stdin):
        if r['name'] == 'akash-provider':
            print(r['chart'].rsplit('-', 1)[-1])
            break
except Exception:
    pass
" 2>/dev/null)

  if [ -z "$CURRENT_CHART" ]; then
    echo "$(date): ERROR could not determine chart version — ABORTING helm upgrade" >> /var/log/miner-eviction.log
  else
    echo "$(date): Using chart version $CURRENT_CHART" >> /var/log/miner-eviction.log
    helm upgrade akash-provider akash/provider \
      --namespace akash-services \
      --version "$CURRENT_CHART" \
      --reuse-values \
      --set "bidpricescript=$PRICE_SCRIPT_B64" >> /var/log/miner-eviction.log 2>&1
    kubectl patch statefulset akash-provider -n akash-services --type=json \
      -p='[{"op":"remove","path":"/spec/template/spec/containers/0/livenessProbe"}]' 2>/dev/null
    echo "$(date): Helm updated to chart $CURRENT_CHART" >> /var/log/miner-eviction.log
  fi
fi

echo "$(date): Eviction complete" >> /var/log/miner-eviction.log
