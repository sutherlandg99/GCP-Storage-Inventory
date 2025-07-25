#!/usr/bin/env bash

# GCP Storage Audit Script (DEBUG VERSION)


# --- Set a timeout command based on the OS ---
if [[ "$OSTYPE" == "darwin"* ]]; then
  # macOS
  TIMEOUT_CMD="gtimeout"
  # Check if gtimeout is installed
  if ! command -v $TIMEOUT_CMD &> /dev/null; then
      echo "❌ 'gtimeout' command not found. Please install with 'brew install coreutils'."
      exit 1
  fi
else
  # Linux
  TIMEOUT_CMD="timeout"
fi

TOTAL_GCS_BYTES=0
TOTAL_PD_GB=0
TOTAL_FILESTORE_GB=0

echo "🔍 Starting GCP storage audit with a 60-second timeout per command..."
echo "Fetching all accessible projects..."

PROJECT_IDS=$(gcloud projects list --format="value(projectId)")
echo "✅ Project list fetched."

if [ -z "$PROJECT_IDS" ]; then
  echo "No accessible projects found. Exiting."
  exit 1
fi

printf "\n%-40s %15s %15s %15s\n" "PROJECT ID" "BUCKETS (GB)" "DISKS (GB)" "FILESTORE (GB)"
echo "-------------------------------------------------------------------------------------------"

for project_id in $PROJECT_IDS; do
  gcloud config set project "$project_id" >/dev/null

  # Run each command with a 60-second timeout
  gcs_bytes=$($TIMEOUT_CMD 60s gcloud storage du --summarize --total 2>/dev/null | tail -n 1)
  gcs_bytes=${gcs_bytes:-0}
  gcs_gb=$(echo "$gcs_bytes / 1024 / 1024 / 1024" | bc -l)
  TOTAL_GCS_BYTES=$(echo "$TOTAL_GCS_BYTES + $gcs_bytes" | bc)

  pd_gb=$($TIMEOUT_CMD 60s gcloud compute disks list --format=json 2>/dev/null | jq '[.[].sizeGb | tonumber] | add')
  pd_gb=${pd_gb:-0}
  TOTAL_PD_GB=$(echo "$TOTAL_PD_GB + $pd_gb" | bc)

  filestore_gb=$($TIMEOUT_CMD 60s gcloud filestore instances list --format=json 2>/dev/null | jq '[.[].capacityGb | tonumber] | add')
  filestore_gb=${filestore_gb:-0}
  TOTAL_FILESTORE_GB=$(echo "$TOTAL_FILESTORE_GB + $filestore_gb" | bc)

  printf "%-40s %15.2f %15.2f %15.2f\n" "$project_id" "$gcs_gb" "$pd_gb" "$filestore_gb"
done

TOTAL_GCS_GB=$(echo "$TOTAL_GCS_BYTES / 1024 / 1024 / 1024" | bc -l)
TOTAL_GCS_TB=$(echo "$TOTAL_GCS_GB / 1024" | bc -l)

echo "-------------------------------------------------------------------------------------------"
echo "\n✅ Audit Complete. Aggregate Totals:"
printf "\n"
printf "📦 Total GCS Bucket Storage:   %.2f GB (%.2f TB)\n" "$TOTAL_GCS_GB" "$TOTAL_GCS_TB"
printf "💿 Total Persistent Disk Storage:  %.2f GB\n" "$TOTAL_PD_GB"
printf "📁 Total Filestore Storage:        %.2f GB\n" "$TOTAL_FILESTORE_GB"
printf "\n"

gcloud config unset project >/dev/null