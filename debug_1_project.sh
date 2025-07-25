#!/bin/bash
#
# A minimal script to debug the gcloud command for the 'sdo-ml' project
# with verbose HTTP logging enabled.
#
set -x # Print each command before executing it.

PROJECT_ID="sdo-ml"

echo "--- [DEBUG] Setting project context for $PROJECT_ID ---"
gcloud config set project "$PROJECT_ID"
gcloud config set billing/quota_project "$PROJECT_ID"

echo "--- [DEBUG] Running the raw gcloud storage command with --log-http ---"
# Added the --log-http flag to see all network requests.
gcloud --log-http storage du --summarize

echo "--- [DEBUG] Cleaning up project context ---"
gcloud config unset billing/quota_project
gcloud config unset project

set +x # Stop printing commands.