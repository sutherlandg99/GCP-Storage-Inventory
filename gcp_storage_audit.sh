#!/bin/bash

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


# Initialize total counters
TOTAL_GCS_BYTES=0
TOTAL_PD_GB=0
TOTAL_FILESTORE_GB=0

echo "🔍 Starting GCP storage audit..."
echo "Fetching all accessible projects. This may take a moment."

# Get a list of all project IDs the user has access to
PROJECT_IDS=$(gcloud projects list --format="value(projectId)")

# Check if any projects were found
if [ -z "$PROJECT_IDS" ]; then
  echo "No accessible projects found. Exiting."
  exit 1
fi

# Print table header
printf "\n%-40s %15s %15s %15s\n" "PROJECT ID" "BUCKETS (GB)" "DISKS (GB)" "FILESTORE (GB)"
echo "-------------------------------------------------------------------------------------------"

# Loop through each project ID
for project_id in $PROJECT_IDS; do
  # Set the gcloud config to the current project to ensure commands run in the correct context
  gcloud config set project "$project_id" >/dev/null

  # --- Get Google Cloud Storage (GCS) Bucket size ---
  # gsutil returns sizes in bytes. We handle errors if the API is disabled or no buckets exist.
  gcs_bytes=$(gsutil -m du -s gs://* 2>/dev/null | awk '{s+=$1} END {print s}')
  gcs_bytes=${gcs_bytes:-0} # Default to 0 if empty
  gcs_gb=$(echo "$gcs_bytes / 1024 / 1024 / 1024" | bc -l)
  TOTAL_GCS_BYTES=$(echo "$TOTAL_GCS_BYTES + $gcs_bytes" | bc)

  # --- Get Persistent Disk (PD) size ---
  # We query for disk sizes in GB. The `jq` command sums the sizes from the JSON output.
  # This is more robust than `awk` if the API is disabled (returns empty json '[]').
  pd_gb=$(gcloud compute disks list --format=json 2>/dev/null | jq '[.[].sizeGb | tonumber] | add')
  pd_gb=${pd_gb:-0} # Default to 0 if null/empty
  TOTAL_PD_GB=$(echo "$TOTAL_PD_GB + $pd_gb" | bc)

  # --- Get Filestore size ---
  # We query for instance capacity in GB.
  filestore_gb=$(gcloud filestore instances list --format=json 2>/dev/null | jq '[.[].capacityGb | tonumber] | add')
  filestore_gb=${filestore_gb:-0} # Default to 0 if null/empty
  TOTAL_FILESTORE_GB=$(echo "$TOTAL_FILESTORE_GB + $filestore_gb" | bc)

  # Print the formatted line for the current project
  printf "%-40s %15.2f %15.2f %15.2f\n" "$project_id" "$gcs_gb" "$pd_gb" "$filestore_gb"
done

# --- Calculate and Print Grand Totals ---
TOTAL_GCS_GB=$(echo "$TOTAL_GCS_BYTES / 1024 / 1024 / 1024" | bc -l)
TOTAL_GCS_TB=$(echo "$TOTAL_GCS_GB / 1024" | bc -l)

echo "-------------------------------------------------------------------------------------------"
echo "\n✅ Audit Complete. Aggregate Totals:"
printf "\n"
printf "📦 Total GCS Bucket Storage:   %.2f GB (%.2f TB)\n" "$TOTAL_GCS_GB" "$TOTAL_GCS_TB"
printf "💿 Total Persistent Disk Storage:  %.2f GB\n" "$TOTAL_PD_GB"
printf "📁 Total Filestore Storage:        %.2f GB\n" "$TOTAL_FILESTORE_GB"
printf "\n"

# Unset the last project from the gcloud config to avoid unexpected behavior later
gcloud config unset project >/dev/null