#!/usr/bin/env bash
# Create the Balatro monitors in integrations/bronto/monitors/*.json (muted until you unmute them with
# `bronto monitors mute <id> --unmute`), each notifying one email address.
# The monitors query datasets by id: set BRONTO_LOGS_DATASET_ID (the logs dataset, e.g. default/balatro)
# and BRONTO_TRACES_DATASET_ID (e.g. .traces/balatro); `bronto datasets list` shows the ids.
# Usage: integrations/bronto/create_monitors.sh you@example.com
set -euo pipefail
email=${1:?usage: $0 <email for notifications>}
: "${BRONTO_LOGS_DATASET_ID:?set BRONTO_LOGS_DATASET_ID}" "${BRONTO_TRACES_DATASET_ID:?set BRONTO_TRACES_DATASET_ID}"
cd "$(dirname "$0")/monitors"
for f in *.json; do
  jq --arg email "$email" --arg logs "$BRONTO_LOGS_DATASET_ID" --arg traces "$BRONTO_TRACES_DATASET_ID" '
    .actions = [{"type": "EMAIL", "email": $email}]
    | walk(if . == "BRONTO_LOGS_DATASET_ID" then $logs elif . == "BRONTO_TRACES_DATASET_ID" then $traces else . end)' "$f" \
    | bronto monitors create --input - -o json | jq -r '"created \(.id // .monitor_id)  \(.name)"'
done
