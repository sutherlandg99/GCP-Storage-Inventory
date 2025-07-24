#!/bin/bash

# GCP Storage Audit Script (DEBUG VERSION)


TOTAL_GCS_BYTES=0
TOTAL_PD_GB=0
TOTAL_FILESTORE_GB=0

echo "🔍 Starting GCP storage audit..."
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
  echo "➡️ Processing project: $project_id"
  echo "   - Setting gcloud config..."
  gcloud config set project "$project_id" >/dev/null

  echo "   - Calculating GCS bucket size (gsutil)..."
  gcs_bytes=$(gsutil -m du -s gs://* 2>/dev/null | awk '{s+=$1} END {print s}')
  gcs_bytes=${gcs_bytes:-0}
  gcs_gb=$(echo "$gcs_bytes / 1024 / 1024 / 1024" | bc -l)
  TOTAL_GCS_BYTES=$(echo "$TOTAL_GCS_BYTES + $gcs_bytes" | bc)
  echo "   - GCS calculation complete."

  echo "   - Calculating Persistent Disk size..."
  pd_gb=$(gcloud compute disks list --format=json 2>/dev/null | jq '[.[].sizeGb | tonumber] | add')
  pd_gb=${pd_gb:-0}
  TOTAL_PD_GB=$(echo "$TOTAL_PD_GB + $pd_gb" | bc)
  echo "   - PD calculation complete."

  echo "   - Calculating Filestore size..."
  filestore_gb=$(gcloud filestore instances list --format=json 2>/dev/null | jq '[.[].capacityGb | tonumber] | add')
  filestore_gb=${filestore_gb:-0}
  TOTAL_FILESTORE_GB=$(echo "$TOTAL_FILESTORE_GB + $filestore_gb" | bc)
  echo "   - Filestore calculation complete."

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