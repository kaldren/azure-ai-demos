#!/usr/bin/env bash
# Safe deploy (step 7a): build in the STAGING slot, then swap it into production only if it's healthy.
#
#   1. zip app/ → deploy to the staging slot. App Service's build (Oryx) runs `pip install` THERE, so a
#      failed build can't break production (in step 6a a failed in-place build caused a 4.5 h outage).
#   2. restart staging, so it runs the code we just shipped (we twice saw a stale process keep serving).
#   3. swap staging → production. Before completing, App Service calls /healthz/deps on the staging
#      instances (WEBSITE_SWAP_WARMUP_PING_PATH). Anything but 200 aborts the swap: production unchanged.
#   4. check production through the gateway (or directly when there's no gateway).
#   Roll back: run the swap again (the previous version is now in staging).
#
# We poll the deployment log instead of `az webapp deploy --track-status`, which hung for 10+ minutes
# after successful deployments in step 3.
set -euo pipefail

RG="${RG:-rg-basic-chatbot}"
APP="${APP:-$(az webapp list -g "$RG" --query "[0].name" -o tsv)}"
SLOT="${SLOT:-staging}"
ZIP="$(mktemp -d)/app.zip"

cd "$(dirname "$0")/app"
zip -qr "$ZIP" . -x '__pycache__/*' '*.pyc' '.*'
latest_id() { az webapp log deployment list -g "$RG" -n "$APP" --slot "$SLOT" --query '[0].id' -o tsv 2>/dev/null || true; }
PREVIOUS_ID="$(latest_id)"

echo "1/4 Uploading $(unzip -l "$ZIP" | tail -1 | awk '{print $2}') files to $APP ($SLOT slot)…"
# Even with --async, the CLI sometimes reports a fast build failure itself (seen in experiment 32).
if ! az webapp deploy -g "$RG" -n "$APP" --slot "$SLOT" --src-path "$ZIP" --type zip --async true --track-status false -o none; then
  echo "BUILD FAILED in $SLOT. Production is untouched. See: az webapp log deployment show -g $RG -n $APP --slot $SLOT"; exit 1
fi

# Wait for *this* deployment (a new ID), then for its status. 4 = success, 3 = failed.
STATUS=""
for i in $(seq 1 60); do
  if [[ "$(latest_id)" != "$PREVIOUS_ID" ]]; then
    STATUS="$(az webapp log deployment list -g "$RG" -n "$APP" --slot "$SLOT" --query '[0].status' -o tsv 2>/dev/null || true)"
  fi
  [[ "$STATUS" == "4" ]] && break
  [[ "$STATUS" == "3" ]] && { echo "BUILD FAILED in $SLOT. Production is untouched. See: az webapp log deployment show -g $RG -n $APP --slot $SLOT"; exit 1; }
  sleep 10
done
[[ "$STATUS" == "4" ]] || { echo "Timed out waiting for the $SLOT deployment (last status: $STATUS). Production is untouched."; exit 1; }

echo "2/4 Restarting $SLOT…"
az webapp restart -g "$RG" -n "$APP" --slot "$SLOT" -o none

echo "3/4 Swapping $SLOT → production (App Service checks /healthz/deps on $SLOT first)…"
if ! az webapp deployment slot swap -g "$RG" -n "$APP" --slot "$SLOT" --target-slot production -o none; then
  echo "SWAP ABORTED: $SLOT didn't pass the warm-up check (/healthz/deps). Production is untouched."
  exit 1
fi

# Step 6b: if an Application Gateway exists, the app's own URL denies public traffic, so check health
# THROUGH the gateway (-k: its certificate is self-signed). Otherwise check the app directly.
AGW_FQDN="$(az network public-ip list -g "$RG" --query "[?starts_with(name,'pip-agw-')].dnsSettings.fqdn | [0]" -o tsv 2>/dev/null || true)"
if [[ -n "$AGW_FQDN" ]]; then URL="https://$AGW_FQDN"; CURL_OPTS=(-k); else
  URL="https://$(az webapp show -g "$RG" -n "$APP" --query defaultHostName -o tsv)"; CURL_OPTS=(); fi
echo "4/4 Checking production at $URL…"
for i in $(seq 1 30); do
  if [[ "$(curl -s ${CURL_OPTS[@]+"${CURL_OPTS[@]}"} -o /dev/null -w '%{http_code}' "$URL/healthz/deps")" == "200" ]]; then
    echo "Done: $URL (dependencies healthy). Roll back with: az webapp deployment slot swap -g $RG -n $APP --slot $SLOT"
    exit 0
  fi
  sleep 10
done
echo "SWAPPED BUT UNHEALTHY: $URL/healthz/deps isn't 200. Roll back now:"
echo "  az webapp deployment slot swap -g $RG -n $APP --slot $SLOT --target-slot production"
exit 1
