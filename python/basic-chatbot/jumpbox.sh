#!/usr/bin/env bash
# Step 7b: reach the jump box INSIDE the VNet through Azure Bastion. You sign in with Entra ID:
# no SSH keys, no passwords, no public IP on the VM. Needs: az login, `az extension add -n bastion -n ssh`,
# and the "Virtual Machine Administrator Login" role on the VM (the Bicep gives it to you).
#
#   ./jumpbox.sh ssh              interactive shell on the jump box
#   ./jumpbox.sh sync             copy this project (code, data, .env) to ~/basic-chatbot on the VM
#   ./jumpbox.sh run '<command>'  run one command there, e.g. ./jumpbox.sh run 'cd basic-chatbot && uv run search.py "taxi"'
#
# On the VM, sign in as YOURSELF once (`az login --use-device-code`), so every action is audited as you.
# The VM's own identity has no roles on purpose: a stolen VM gets nothing.
set -euo pipefail

RG="${RG:-rg-basic-chatbot}"
BASTION="${BASTION:-$(az network bastion list -g "$RG" --query "[0].name" -o tsv)}"
VM_ID="${VM_ID:-$(az vm list -g "$RG" --query "[?starts_with(name,'vm-jumpbox-')].id | [0]" -o tsv)}"
PORT="${PORT:-2222}"
[[ -n "$BASTION" && -n "$VM_ID" ]] || { echo "No Bastion or jump box in $RG (deployBastion=false?)"; exit 1; }

# The tunnel makes the VM's port 22 appear on localhost:$PORT. The host key is pinned on first use, under
# the VM's unique vmId: a RECREATED jump box is a new host (no scary warning), but a changed key on the
# SAME VM is still refused.
VM_UNIQUE_ID="$(az vm show --ids "$VM_ID" --query vmId -o tsv)"
SSH_OPTS=(-o UserKnownHostsFile="$HOME/.ssh/known_hosts_jumpbox" -o StrictHostKeyChecking=accept-new
  -o HostKeyAlias="jumpbox-$VM_UNIQUE_ID" -o LogLevel=ERROR)

with_tunnel() {
  az network bastion tunnel -g "$RG" -n "$BASTION" --target-resource-id "$VM_ID" \
    --resource-port 22 --port "$PORT" >/dev/null 2>&1 &
  TUNNEL_PID=$! # global: the EXIT trap runs after this function's locals are gone
  trap 'kill "$TUNNEL_PID" 2>/dev/null || true' EXIT
  for _ in $(seq 1 30); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 1; done
  nc -z 127.0.0.1 "$PORT" 2>/dev/null || { echo "Tunnel didn't open on port $PORT"; exit 1; }
  # az ssh gets a short-lived SSH certificate for YOUR Entra identity, and the VM's Entra login
  # extension checks your role. Your user name on the VM is your sign-in name.
  az ssh vm --ip 127.0.0.1 --port "$PORT" -- "${SSH_OPTS[@]}" "$@"
}

case "${1:-}" in
  ssh)
    az network bastion ssh -g "$RG" -n "$BASTION" --target-resource-id "$VM_ID" --auth-type AAD ;;
  run)
    shift; with_tunnel "$*" ;;
  sync)
    cd "$(dirname "$0")"
    # Code + data + .env (endpoints and names only; everything is keyless). Not .venv: uv rebuilds it there.
    COPYFILE_DISABLE=1 tar --no-xattrs -czf - --exclude .venv --exclude __pycache__ --exclude '*.pyc' . \
      | with_tunnel 'mkdir -p ~/basic-chatbot && tar xzf - -C ~/basic-chatbot && echo "synced to ~/basic-chatbot on $(hostname)"' ;;
  *)
    sed -n '2,11p' "$0"; exit 1 ;;
esac
