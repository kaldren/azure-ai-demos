#!/usr/bin/env bash
# Zip-deploy app/ to the App Service created by infra/main.bicep.
# App Service's build step (Oryx) runs `pip install -r requirements.txt` because the Bicep sets
# SCM_DO_BUILD_DURING_DEPLOYMENT=true. The startup command (gunicorn + uvicorn) is also set in Bicep.
#
# We don't use `az webapp deploy --track-status true`: in step 3 it kept waiting for 10+ minutes
# after the deployment had already succeeded. Instead we poll the deployment log ourselves.
set -euo pipefail

RG="${RG:-rg-basic-chatbot}"
APP="${APP:-$(az webapp list -g "$RG" --query "[0].name" -o tsv)}"
ZIP="$(mktemp -d)/app.zip"

cd "$(dirname "$0")/app"
zip -qr "$ZIP" . -x '__pycache__/*' '*.pyc' '.*'
latest_id() { az webapp log deployment list -g "$RG" -n "$APP" --query '[0].id' -o tsv 2>/dev/null || true; }
PREVIOUS_ID="$(latest_id)"

echo "Uploading $(unzip -l "$ZIP" | tail -1 | awk '{print $2}') files to $APP…"
az webapp deploy -g "$RG" -n "$APP" --src-path "$ZIP" --type zip --async true --track-status false -o none

# Wait for *this* deployment (a new ID), then for its status. 4 = success, 3 = failed.
# Build + restart usually takes 2–5 minutes.
STATUS=""
for i in $(seq 1 60); do
  if [[ "$(latest_id)" != "$PREVIOUS_ID" ]]; then
    STATUS="$(az webapp log deployment list -g "$RG" -n "$APP" --query '[0].status' -o tsv 2>/dev/null || true)"
  fi
  [[ "$STATUS" == "4" ]] && break
  [[ "$STATUS" == "3" ]] && { echo "Deployment FAILED. See: az webapp log deployment show -g $RG -n $APP"; exit 1; }
  sleep 10
done
[[ "$STATUS" == "4" ]] || { echo "Timed out waiting for the deployment (last status: $STATUS)"; exit 1; }

# Twice (steps 5 and 6a) the new build was deployed but the OLD process kept serving requests.
# Restart explicitly so the health check below tests the code we just shipped.
az webapp restart -g "$RG" -n "$APP" -o none

URL="https://$(az webapp show -g "$RG" -n "$APP" --query defaultHostName -o tsv)"
# Healthy = the app answers AND its dependencies (Foundry, app Cosmos DB) respond over the private path.
# Added after a failed build (blocked by the firewall) left the app returning 5xx for 4.5 hours unnoticed.
for i in $(seq 1 30); do
  if [[ "$(curl -s -o /dev/null -w '%{http_code}' "$URL/healthz/deps")" == "200" ]]; then
    echo "Done: $URL (dependencies healthy)"; exit 0
  fi
  sleep 10
done
echo "DEPLOYED BUT UNHEALTHY: $URL/healthz/deps isn't 200. The app may be down."
echo "Check: curl $URL/healthz/deps ; az webapp log tail -g $RG -n $APP"
exit 1
