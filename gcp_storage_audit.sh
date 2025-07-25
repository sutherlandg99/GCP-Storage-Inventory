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

TOTAL_GCS_BYTES=0
TOTAL_PD_GB=0
TOTAL_FILESTORE_GB=0

echo "🔍 Starting GCP storage audit..."
echo "Fetching all accessible projects..."

# Ensure the cloudresourcemanager API is enabled to get the project list
gcloud services enable cloudresourcemanager.googleapis.com --quiet

# <<< FIX: The original method of storing project IDs in a variable and using a 'for'
# loop is not robust. Piping directly to a 'while read' loop is the standard, safe way
# to process lines of output.
PROJECT_IDS_COMMAND="gcloud projects list --format='value(projectId)'"

echo "✅ Project list fetched."

printf "\n%-40s %15s %15s %15s\n" "PROJECT ID" "BUCKETS (GB)" "DISKS (GB)" "FILESTORE (GB)"
echo "-------------------------------------------------------------------------------------------"

# This function prompts the user to enable a specific API for a project
prompt_to_enable_api() {
  local project_id="$1"
  local api_name="$2"
  local enable_api=""

  # Use read's -r option to handle backslashes correctly
  read -r -p "API [$api_name] is not enabled for project [$project_id]. Enable it now? (y/N) " enable_api
  if [[ "$enable_api" =~ ^[Yy]$ ]]; then
    echo "Enabling $api_name..."
    # Add --quiet to reduce verbose output
    if gcloud services enable "$api_name" --project="$project_id" --quiet; then
        echo "✅ Successfully enabled $api_name."
        return 0 # Success
    else
        echo "❌ Failed to enable $api_name."
        return 1 # Failure
    fi
  else
    echo "Skipping..."
    return 1 # Failure
  fi
}

# Regex to check if a string is a number
REGEX_IS_NUM='^[0-9]+([.][0-9]+)?$'

eval "$PROJECT_IDS_COMMAND" | while read -r project_id; do
  # <<< FIX: Set project config quietly to avoid polluting script output.
  gcloud config set project "$project_id" --quiet
  gcs_gb=0
  pd_gb=0
  filestore_gb=0

  # --- GCS Buckets ---
  # <<< FIX: This section is rewritten for massive performance and reliability gains.
  # Instead of looping through every bucket, we use one MQL query to sum the storage for the whole project.
  PROJECT_GCS_BYTES=0
  
  # The MQL query requires the Monitoring API. GCS metrics also require the Storage API.
  # We check for a failure and then prompt the user, which is simpler than checking proactively.
  MQL_QUERY="fetch gcs_bucket::storage.googleapis.com/storage/total_bytes | group_by 1d, [value_total_bytes_sum: sum(value.total_bytes)] | within 24h"
  API_RESPONSE=$(curl -s -X POST "https://monitoring.googleapis.com/v3/projects/$project_id/timeSeries:query" \
    -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    -H "Content-Type: application/json" --data-raw "{'query': '$MQL_QUERY'}")

  # Check if the API call failed because an API is not enabled.
  if [[ $API_RESPONSE == *"service is not enabled"* || $API_RESPONSE == *"PermissionDenied"* ]]; then
      echo "GCS query failed for project '$project_id'. This usually means the Monitoring or Storage API is disabled."
      # The error could be for monitoring.googleapis.com or storage.googleapis.com. Prompt for both.
      prompt_to_enable_api "$project_id" "storage.googleapis.com"
      if prompt_to_enable_api "$project_id" "monitoring.googleapis.com"; then
          # Retry the API call if the user enabled the API.
          echo "Retrying GCS query for '$project_id'..."
          API_RESPONSE=$(curl -s -X POST "https://monitoring.googleapis.com/v3/projects/$project_id/timeSeries:query" \
            -H "Authorization: Bearer $(gcloud auth print-access-token)" \
            -H "Content-Type: application/json" --data-raw "{'query': '$MQL_QUERY'}")
      fi
  fi
  
  bytes=$(echo "$API_RESPONSE" | jq -r '.timeSeriesData[0].pointData[0].values[0].int64Value // "0"')
  PROJECT_GCS_BYTES=${bytes:-0} # Bash parameter expansion to default to 0 if bytes is null/empty
  gcs_gb=$(echo "$PROJECT_GCS_BYTES / 1024 / 1024 / 1024" | bc -l)
  TOTAL_GCS_BYTES=$(echo "$TOTAL_GCS_BYTES + $PROJECT_GCS_BYTES" | bc)

  # --- Persistent Disks ---
  pd_output_raw=$(gcloud compute disks list --project="$project_id" --format=json 2>&1)
  if [[ $pd_output_raw == *"API [compute.googleapis.com] is not enabled"* ]]; then
    if prompt_to_enable_api "$project_id" "compute.googleapis.com"; then
      pd_output_raw=$(gcloud compute disks list --project="$project_id" --format=json 2>&1)
    fi
  fi
  pd_gb_raw=$(echo "$pd_output_raw" | grep -v "API.*is not enabled" | jq '[.[]?.sizeGb // 0] | add')
  if ! [[ $pd_gb_raw =~ $REGEX_IS_NUM ]] ; then pd_gb=0; else pd_gb=$pd_gb_raw; fi
  TOTAL_PD_GB=$(echo "$TOTAL_PD_GB + $pd_gb" | bc)

  # --- Filestore ---
  filestore_output_raw=$(gcloud filestore instances list --project="$project_id" --format=json 2>&1)
  if [[ $filestore_output_raw == *"API [file.googleapis.com] is not enabled"* ]]; then
    if prompt_to_enable_api "$project_id" "file.googleapis.com"; then
      filestore_output_raw=$(gcloud filestore instances list --project="$project_id" --format=json 2>&1)
    fi
  fi
  filestore_gb_raw=$(echo "$filestore_output_raw" | grep -v "API.*is not enabled" | jq '[.[]?.capacityGb // 0] | add')
  if ! [[ $filestore_gb_raw =~ $REGEX_IS_NUM ]] ; then filestore_gb=0; else filestore_gb=$filestore_gb_raw; fi
  TOTAL_FILESTORE_GB=$(echo "$TOTAL_FILESTORE_GB + $filestore_gb" | bc)

  printf "%-40s %15.2f %15.2f %15.2f\n" "$project_id" "$gcs_gb" "$pd_gb" "$filestore_gb"
done

# --- Final Summation ---
TOTAL_GCS_GB=$(echo "$TOTAL_GCS_BYTES / 1024 / 1024 / 1024" | bc -l)
TOTAL_GCS_TB=$(echo "$TOTAL_GCS_GB / 1024" | bc -l)

echo "-------------------------------------------------------------------------------------------"
echo ""
echo "✅ Audit Complete. Aggregate Totals:"
printf "\n"
printf "📦 Total GCS Bucket Storage:      %.2f GB (%.2f TB)\n" "$TOTAL_GCS_GB" "$TOTAL_GCS_TB"
printf "💿 Total Persistent Disk Storage: %.2f GB\n" "$TOTAL_PD_GB"
printf "📁 Total Filestore Storage:       %.2f GB\n" "$TOTAL_FILESTORE_GB"
printf "\n"

# Unset the last-used project to clean up the user's gcloud config state.
gcloud config unset project --quiet