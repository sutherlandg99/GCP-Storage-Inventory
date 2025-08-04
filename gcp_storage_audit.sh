#!/usr/bin/env bash

# GCP Storage Audit Script
# This script iterates through all GCP projects the user has access to and reports 
# on the storage usage for GCS Buckets, Persistent Disks, and Filestore instances.
# It provides both a per-project breakdown and a final aggregate total.

# Requirements:
# 1. `gcloud` CLI installed and authenticated (`gcloud auth login`).
# 2. `jq` command-line JSON processor. Install with `sudo apt-get install jq` or `brew install jq`.
# 3. Sufficient IAM permissions (e.g., Project Viewer) on the projects to be audited.
# 4. The required APIs (compute.googleapis.com, file.googleapis.com, storage.googleapis.com)
#    must be enabled in each project for its data to be reported.

# This sets the commandline to a arbitrary GCP project, so the gcloud commands don't error out. 
# This can be any GCP project the user has access to!
# gcloud config set project sdo-ml

TOTAL_GCS_BYTES=0
TOTAL_PD_GB=0
TOTAL_FILESTORE_GB=0

echo "🔍 Starting GCP storage audit..."
echo "Fetching all accessible projects..."

# Ensure the cloudresourcemanager API is enabled to get the project list
gcloud services enable cloudresourcemanager.googleapis.com --quiet 2>/dev/null

PROJECT_IDS_COMMAND="gcloud projects list --format='value(projectId)'"
echo "✅ Project list fetched."

printf "\n%-40s %15s %15s %15s\n" "PROJECT ID" "BUCKETS (GB)" "DISKS (GB)" "FILESTORE (GB)"
echo "-------------------------------------------------------------------------------------------"

REGEX_IS_NUM='^[0-9]+([.][0-9]+)?$'

eval "$PROJECT_IDS_COMMAND" | while read -r project_id; do
  gcloud config set project "$project_id" --quiet
  
  # Proactively enable all necessary APIs. This is silent unless there's an error.
  gcloud services enable \
    compute.googleapis.com \
    storage.googleapis.com \
    file.googleapis.com \
    monitoring.googleapis.com \
    --project="$project_id" --quiet 2>/dev/null
  
  # A short sleep is recommended to prevent race conditions after enabling an API.
  sleep 5

  gcs_gb=0
  pd_gb=0
  filestore_gb=0

  # --- GCS Buckets ---
  PROJECT_GCS_BYTES=0
  MQL_QUERY="fetch gcs_bucket::storage.googleapis.com/storage/total_bytes | group_by 1d, [value_total_bytes_sum: sum(value.total_bytes)] | within 5d"
  API_RESPONSE=$(curl -s -X POST "https://monitoring.googleapis.com/v3/projects/$project_id/timeSeries:query" \
    -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    -H "Content-Type: application/json" --data-raw "{'query': '$MQL_QUERY'}")
  
  bytes=$(echo "$API_RESPONSE" | jq '[.timeSeriesData[]?.pointData[0]?.values[0]?.doubleValue // 0] | add')
  PROJECT_GCS_BYTES=${bytes:-0}
  gcs_gb=$(echo "scale=2; $PROJECT_GCS_BYTES / 1024 / 1024 / 1024" | bc -l)
  TOTAL_GCS_BYTES=$(echo "$TOTAL_GCS_BYTES + $PROJECT_GCS_BYTES" | bc)

  # --- Persistent Disks ---
  pd_gb=0
  pd_output_raw=$(gcloud compute disks list --filter="" --format=json 2>&1)
  
  if [[ "$pd_output_raw" == "{"* || "$pd_output_raw" == "["* ]]; then
    # This robust jq filter handles all valid JSON outputs from the gcloud command.
    JQ_FILTER_PD='if type == "object" and .items then [.items[].disks[]?.sizeGb // "0"] | map(tonumber) | add // 0 else [.[]?.sizeGb // "0"] | map(tonumber) | add // 0 end'
    pd_gb_raw=$(echo "$pd_output_raw" | jq "$JQ_FILTER_PD")

    if [[ $pd_gb_raw =~ $REGEX_IS_NUM ]] ; then
        pd_gb=$pd_gb_raw
    fi
  elif [ -n "$pd_output_raw" ]; then
    printf "%-40s %15.2f %15s %15s\n" "$project_id" "$gcs_gb" "ERROR" "-"
    echo "      └─ ERROR fetching disks: $(echo "$pd_output_raw" | head -n 1)"
    continue
  fi
  TOTAL_PD_GB=$(echo "$TOTAL_PD_GB + $pd_gb" | bc)

  # --- Filestore ---
  filestore_gb=0
  filestore_output_raw=$(gcloud filestore instances list --project="$project_id" --region=- --format=json 2>&1)
  
  if [[ "$filestore_output_raw" == "["* ]]; then
    # The 'add // 0' ensures jq returns 0 for an empty array instead of null.
    filestore_gb_raw=$(echo "$filestore_output_raw" | jq '[.[]?.capacityGb // 0] | add // 0')
    if [[ $filestore_gb_raw =~ $REGEX_IS_NUM ]] ; then
        filestore_gb=$filestore_gb_raw
    fi
  elif [ -n "$filestore_output_raw" ]; then
    printf "%-40s %15.2f %15.2f %15s\n" "$project_id" "$gcs_gb" "$pd_gb" "ERROR"
    echo "      └─ ERROR fetching filestore: $(echo "$filestore_output_raw" | head -n 1)"
    continue
  fi
  TOTAL_FILESTORE_GB=$(echo "$TOTAL_FILESTORE_GB + $filestore_gb" | bc)

  printf "%-40s %15.2f %15.2f %15.2f\n" "$project_id" "$gcs_gb" "$pd_gb" "$filestore_gb"
done

# --- Final Summation ---
TOTAL_GCS_GB=$(echo "scale=2; $TOTAL_GCS_BYTES / 1024 / 1024 / 1024" | bc -l)
TOTAL_GCS_TB=$(echo "scale=2; $TOTAL_GCS_GB / 1024" | bc -l)

echo "-------------------------------------------------------------------------------------------"
echo ""
echo "✅ Audit Complete. Aggregate Totals:"
printf "\n"
printf "📦 Total GCS Bucket Storage:      %.2f GB (%.2f TB)\n" "$TOTAL_GCS_GB" "$TOTAL_GCS_TB"
printf "💿 Total Persistent Disk Storage: %.2f GB\n" "$TOTAL_PD_GB"
printf "📁 Total Filestore Storage:       %.2f GB\n" "$TOTAL_FILESTORE_GB"
printf "\n"

gcloud config unset project --quiet