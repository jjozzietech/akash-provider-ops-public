#!/bin/bash
#
# check-cpu-miners.sh — behavioural CPU-load miner detection + eviction
#
# What it does:
#   Every 10 minutes (via cron), SSHs into each worker node and checks
#   load average. If load exceeds threshold, inspects top CPU processes
#   for AKASH_OWNER environment variable to identify the tenant, then:
#     1. Closes ALL leases for that tenant
#     2. Force-deletes the affected namespaces
#     3. Appends the tenant address to your bid script's BLACKLIST array
#     4. Re-runs `helm upgrade` with the updated blacklist injected
#
# Catches what evict-miners.sh cannot — hidden miners running under
# innocuous process names (e.g. `python3 main.py`, `groundstate --mine`)
# that don't match the image/name keyword patterns. Behavioural detection
# based on sustained high CPU rather than string patterns.
#
# Placeholders (replace before use):
#   <YOUR_PROVIDER_WALLET_ADDRESS>  — your provider's on-chain address
#   <PROVIDER_BID_SCRIPT_PATH>       — path to your bid pricing script
#                                      (must contain a BLACKLIST=( ... )
#                                      bash array)
#
# Prerequisites:
#   - Passwordless SSH from this control host to all worker nodes as root
#     (or a user with permission to read /proc/*/environ)
#   - `bc` installed on this host for float comparison
#
# Suggested cron entry (edit with `crontab -e`):
#   */10 * * * * /usr/local/bin/check-cpu-miners.sh
#
# Log location: /var/log/miner-eviction.log
#
# WARNING — tuning required:
#   The default CPU_THRESHOLD=20 (load average) is calibrated for nodes
#   with roughly 16-24 cores under a light-to-medium tenant mix. Very
#   large nodes need a higher threshold; very small nodes need lower.
#   Sustained legitimate CPU workloads (ML training, video encoding,
#   scientific compute) can trigger false positives. Review your typical
#   worker load profile with `uptime` across a normal day before tuning.
#
# License: MIT — see LICENSE in repo root.
#

export PATH=/usr/local/bin:/usr/bin:/bin:$PATH

PROVIDER="<YOUR_PROVIDER_WALLET_ADDRESS>"
CPU_THRESHOLD=20  # Load average threshold per node
PRICE_SCRIPT="<PROVIDER_BID_SCRIPT_PATH>"

# Get all worker nodes (exclude control-plane)
NODES=$(kubectl get nodes --no-headers | grep -v "control-plane\|master" | awk '{print $1}')

HELM_UPGRADE_NEEDED=false

for node in $NODES; do
  NODE_IP=$(kubectl get node $node -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
  if [ -z "$NODE_IP" ]; then continue; fi

  # Check load average
  LOAD=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@$NODE_IP "cat /proc/loadavg 2>/dev/null | awk '{print \$1}'" 2>/dev/null)
  if [ -z "$LOAD" ]; then continue; fi

  EXCEEDED=$(echo "$LOAD > $CPU_THRESHOLD" | bc -l 2>/dev/null)
  if [ "$EXCEEDED" != "1" ]; then continue; fi

  echo "$(date): HIGH LOAD on $node ($NODE_IP): $LOAD" >> /var/log/miner-eviction.log

  # Find high CPU processes and extract their tenant owner from AKASH_OWNER env var
  OWNER=$(ssh -o ConnectTimeout=5 root@$NODE_IP "
    for pid in \$(ps aux --sort=-%cpu | awk 'NR>1 && \$3>100 {print \$2}' | head -5); do
      cat /proc/\$pid/environ 2>/dev/null | tr '\0' '\n' | grep 'AKASH_OWNER' | head -1
    done
  " 2>/dev/null | sort -u | head -1 | cut -d= -f2)

  if [ -z "$OWNER" ]; then continue; fi
  echo "$(date): High CPU miner detected on $node: $OWNER" >> /var/log/miner-eviction.log

  # Close all leases for this owner
  kubectl get namespaces --no-headers 2>/dev/null | grep Active | awk '{print $1}' | while read ns; do
    NS_OWNER=$(kubectl get namespace $ns -o yaml 2>/dev/null | grep "lease.id.owner" | awk '{print $2}')
    if [[ "$NS_OWNER" == "$OWNER" ]]; then
      DSEQ=$(kubectl get namespace $ns -o yaml 2>/dev/null | grep "lease.id.dseq" | awk '{print $2}' | tr -d '"')
      echo "$(date): Closing high-CPU lease $OWNER/$DSEQ" >> /var/log/miner-eviction.log
      provider-services tx market lease close \
        --owner $OWNER --dseq $DSEQ --gseq 1 --oseq 1 \
        --node https://rpc.akashnet.net:443 \
        --from $PROVIDER \
        --keyring-backend test --chain-id akashnet-2 --yes 2>/dev/null
      kubectl delete namespace $ns --force --grace-period=0 2>/dev/null &
      sleep 2
    fi
  done

  # Auto-blacklist (same pattern as evict-miners.sh)
  if ! grep -q "$OWNER" "$PRICE_SCRIPT"; then
    echo "$(date): Auto-blacklisting $OWNER" >> /var/log/miner-eviction.log
    sed -i "s/BLACKLIST=(/BLACKLIST=(\n  \"$OWNER\"/" "$PRICE_SCRIPT"
    HELM_UPGRADE_NEEDED=true
  fi
done

# Update helm if new addresses blacklisted
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
