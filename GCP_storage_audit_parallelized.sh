#!/usr/bin/env bash

# --- GCP Multi-Project Storage Audit Script (Parallelized & macOS Compatible) ---
# This script iterates through all GCP projects the user has access to and reports 
# on the storage usage for GCS Buckets, Persistent Disks, and Filestore instances.
# Features parallel processing for significant performance improvements.

# Requirements:
# 1. `gcloud` CLI installed and authenticated (`gcloud auth login`).
# 2. `jq` command-line JSON processor. Install with `sudo apt-get install jq` or `brew install jq`.
# 3. `bc` calculator for arithmetic operations.
# 4. Sufficient IAM permissions (e.g., Project Viewer) on the projects to be audited.

# --- Configuration ---
TIMESTAMP=$(date +%s)
LOG_FILE="gcp_multi_project_audit_${TIMESTAMP}.txt"
CSV_FILE="gcp_storage_inventory_${TIMESTAMP}.csv"

# Parallelization settings
MAX_CONCURRENT_BUCKETS=32  # Lower number of concurrent threads for better stability

# Global totals
TOTAL_GCS_BYTES=0
TOTAL_PD_BYTES=0
TOTAL_FILESTORE_BYTES=0

# Create temporary directory for parallel processing
TEMP_DIR="/tmp/gcp_audit_$$"
mkdir -p "$TEMP_DIR"

# Cleanup function
cleanup() {
    echo "🧹 Cleaning up temporary files..."
    rm -rf "$TEMP_DIR"
    # Kill any remaining background jobs
    jobs -p | xargs -r kill 2>/dev/null || true
}
trap cleanup EXIT

# --- Setup Logging ---
exec 3>&1 4>&2
exec > >(tee -a "$LOG_FILE") 2>&1

echo "🚀 Starting GCP Multi-Project Storage Audit (Parallelized)"
echo "=================================================================="
echo "⚙️  Parallelization Settings:"
echo "   - Max concurrent buckets per project: $MAX_CONCURRENT_BUCKETS"
echo "   - Max concurrent projects: $MAX_CONCURRENT_PROJECTS"
echo "=================================================================="

# Initialize CSV file with headers
echo "GCP_Project,Resource_Type,Resource_Name,Location_Zone,Creation_Time,Created_By,Last_Updated,Type,Labels,Storage_Size_GB,Storage_Size_Bytes" > "$CSV_FILE"
echo "✅ CSV inventory file initialized: $CSV_FILE"

# Check if required tools are available
command -v gcloud >/dev/null 2>&1 || { echo "❌ Error: gcloud CLI not found"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "❌ Error: jq not found"; exit 1; }
command -v bc >/dev/null 2>&1 || { echo "❌ Error: bc not found"; exit 1; }

# Function to safely escape CSV fields
escape_csv_field() {
    local field="$1"
    # Replace quotes with double quotes and wrap in quotes if contains comma, quote, or newline
    if [[ "$field" == *","* ]] || [[ "$field" == *"\""* ]] || [[ "$field" == *"\n"* ]]; then
        field=$(echo "$field" | sed 's/"/""/g')
        echo "\"$field\""
    else
        echo "$field"
    fi
}

# Function to add row to CSV (thread-safe using simpler approach)
add_csv_row() {
    local project="$1"
    local resource_type="$2"
    local resource_name="$3"
    local location_zone="$4"
    local creation_time="$5"
    local created_by="$6"
    local last_updated="$7"
    local type="$8"
    local labels="$9"
    local storage_size_gb="${10}"
    local storage_size_bytes="${11}"
    
    # Escape all fields
    project=$(escape_csv_field "$project")
    resource_type=$(escape_csv_field "$resource_type")
    resource_name=$(escape_csv_field "$resource_name")
    location_zone=$(escape_csv_field "$location_zone")
    creation_time=$(escape_csv_field "$creation_time")
    created_by=$(escape_csv_field "$created_by")
    last_updated=$(escape_csv_field "$last_updated")
    type=$(escape_csv_field "$type")
    labels=$(escape_csv_field "$labels")
    storage_size_gb=$(escape_csv_field "$storage_size_gb")
    storage_size_bytes=$(escape_csv_field "$storage_size_bytes")
    
    # Simple file append (good enough for most use cases)
    echo "$project,$resource_type,$resource_name,$location_zone,$creation_time,$created_by,$last_updated,$type,$labels,$storage_size_gb,$storage_size_bytes" >> "$CSV_FILE"
}

# Function to process a single GCS bucket in parallel
process_single_bucket() {
    local project_id="$1"
    local bucket_uri="$2"
    local bucket_index="$3"
    local total_buckets="$4"
    
    local result_file="$TEMP_DIR/bucket_${project_id}_${bucket_index}.result"
    
    echo "[$bucket_index/$total_buckets] 🔄 Processing bucket: $bucket_uri" >&3
    
    # Initialize result with defaults
    local bucket_name="$bucket_uri"
    local bucket_location="unknown"
    local storage_class="unknown"
    local created_time="unknown"
    local updated_time="unknown"
    local created_by="unknown"
    local labels="none"
    local bucket_bytes="0"
    local bucket_size_gb="0"
    local status="processing"
    
    # Collect bucket metadata in parallel with size calculation
    local metadata_file="$TEMP_DIR/bucket_${project_id}_${bucket_index}.metadata"
    gcloud storage buckets describe "$bucket_uri" --format=json > "$metadata_file" 2>/dev/null &
    metadata_pid=$!
    
    # Calculate bucket size
    local temp_output="$TEMP_DIR/bucket_${project_id}_${bucket_index}.du"
    local temp_error="$TEMP_DIR/bucket_${project_id}_${bucket_index}.err"
    
    # Use gsutil du as fallback - it's often more reliable for large buckets
    # Try gcloud storage du first, then gsutil du if that fails
    gcloud storage du --summarize "$bucket_uri" > "$temp_output" 2> "$temp_error" &
    du_pid=$!
    
    # Also try gsutil du in parallel as backup
    local temp_output_gsutil="$TEMP_DIR/bucket_${project_id}_${bucket_index}.gsutil"
    gsutil du -s "$bucket_uri" > "$temp_output_gsutil" 2>/dev/null &
    gsutil_pid=$!
    
    # Wait for both operations
    wait $metadata_pid 2>/dev/null
    wait $du_pid
    du_exit_code=$?
    wait $gsutil_pid 2>/dev/null
    gsutil_exit_code=$?
    
    # Process metadata
    if [ -s "$metadata_file" ]; then
        bucket_name=$(jq -r '.name // .id // "unknown"' "$metadata_file" 2>/dev/null || echo "unknown")
        bucket_location=$(jq -r '.location // .locationType // "unknown"' "$metadata_file" 2>/dev/null || echo "unknown")
        storage_class=$(jq -r '.default_storage_class // .storageClass // .defaultStorageClass // .storage_class // "unknown"' "$metadata_file" 2>/dev/null || echo "unknown")
        created_time=$(jq -r '.creation_time // .timeCreated // .createTime // .created // .creationTimestamp // "unknown"' "$metadata_file" 2>/dev/null || echo "unknown")
        updated_time=$(jq -r '.update_time // .updated // .timeUpdated // .updateTime // .lastModified // "unknown"' "$metadata_file" 2>/dev/null || echo "unknown")
        created_by=$(jq -r '.owner.entity // .owner.entityId // .createdBy // .created_by // "unknown"' "$metadata_file" 2>/dev/null || echo "unknown")
        
        # Check labels for creator info if still unknown
        if [ "$created_by" = "unknown" ]; then
            created_by=$(jq -r '.labels["created-by"] // .labels.createdBy // .labels.creator // "unknown"' "$metadata_file" 2>/dev/null || echo "unknown")
        fi
        
        # Extract labels
        local labels_json=$(jq -r '.labels // {}' "$metadata_file" 2>/dev/null || echo "{}")
        if [ "$labels_json" != "{}" ] && [ "$labels_json" != "null" ]; then
            labels=$(echo "$labels_json" | jq -r 'to_entries[] | "\(.key)=\(.value)"' 2>/dev/null | paste -sd "; " - || echo "none")
        else
            labels="none"
        fi
    fi
    
    # Process size calculation - try both gcloud and gsutil results
    bucket_bytes="0"
    bucket_size_gb="0"
    
    # First try gcloud storage du results
    if [ $du_exit_code -eq 0 ] && [ -s "$temp_output" ]; then
        local bucket_size_output=$(cat "$temp_output")
        
        if [ -n "$bucket_size_output" ]; then
            bucket_bytes=$(echo "$bucket_size_output" | grep -E "^[0-9]+" | tail -1 | awk '{print $1}' 2>/dev/null || echo "0")
            
            if [[ ! "$bucket_bytes" =~ ^[0-9]+$ ]]; then
                bucket_bytes=$(echo "$bucket_size_output" | grep -oE '[0-9]+' | tail -1 2>/dev/null || echo "0")
            fi
        fi
    fi
    
    # If gcloud failed or gave 0, try gsutil results
    if [[ "$bucket_bytes" == "0" || "$bucket_bytes" == "" ]] && [ $gsutil_exit_code -eq 0 ] && [ -s "$temp_output_gsutil" ]; then
        echo "  🔄 gcloud gave 0 bytes, trying gsutil..." >&3
        local gsutil_output=$(cat "$temp_output_gsutil")
        
        if [ -n "$gsutil_output" ]; then
            # gsutil du output format: "12345  gs://bucket-name/"
            bucket_bytes=$(echo "$gsutil_output" | awk '{print $1}' 2>/dev/null || echo "0")
            
            if [[ "$bucket_bytes" =~ ^[0-9]+$ ]] && [ "$bucket_bytes" -gt 0 ]; then
                echo "  ✓ gsutil found: $bucket_bytes bytes" >&3
            else
                bucket_bytes="0"
            fi
        fi
    fi
    
    # Final validation and processing
    if [[ "$bucket_bytes" =~ ^[0-9]+$ ]] && [ "$bucket_bytes" -gt 0 ]; then
        bucket_size_gb=$(echo "scale=6; $bucket_bytes / 1073741824" | bc -l 2>/dev/null || echo "0")
        status="success"
        
        # Convert to human readable for display
        local human_size size_unit
        if [ "$bucket_bytes" -gt 1099511627776 ]; then
            human_size=$(echo "scale=2; $bucket_bytes / 1099511627776" | bc -l 2>/dev/null || echo "0")
            size_unit="TB"
        elif [ "$bucket_bytes" -gt 1073741824 ]; then
            human_size=$(echo "scale=2; $bucket_bytes / 1073741824" | bc -l 2>/dev/null || echo "0")
            size_unit="GB"
        elif [ "$bucket_bytes" -gt 1048576 ]; then
            human_size=$(echo "scale=2; $bucket_bytes / 1048576" | bc -l 2>/dev/null || echo "0")
            size_unit="MB"
        else
            human_size=$bucket_bytes
            size_unit="bytes"
        fi
        
        echo "[$bucket_index/$total_buckets] ✅ $bucket_uri: $human_size $size_unit" >&3
    else
        bucket_bytes="0"
        bucket_size_gb="0"
        status="empty"
        echo "[$bucket_index/$total_buckets] ✅ $bucket_uri: 0 bytes (empty)" >&3
    fi
    
    # Write result to file with proper escaping
    cat > "$result_file" << EOF
bucket_name=$bucket_name
bucket_location=$bucket_location
storage_class=$storage_class
created_time=$created_time
updated_time=$updated_time
created_by=$created_by
labels='$labels'
bucket_bytes=$bucket_bytes
bucket_size_gb=$bucket_size_gb
status=$status
EOF
    
    # Cleanup temp files
    rm -f "$temp_output" "$temp_error" "$temp_output_gsutil" "$metadata_file"
}

# Function to manage parallel bucket processing
process_buckets_parallel() {
    local project_id="$1"
    local bucket_list="$2"
    
    if [ -z "$bucket_list" ]; then
        echo "No GCS buckets found in project: $project_id"
        echo "0"
        return 0
    fi
    
    # Convert bucket list to array
    local -a buckets
    while IFS= read -r bucket_uri; do
        if [ -n "$bucket_uri" ]; then
            buckets+=("$bucket_uri")
        fi
    done <<< "$bucket_list"
    
    local total_buckets=${#buckets[@]}
    echo "📦 Found $total_buckets buckets to process in parallel..."
    
    # Process buckets in batches
    local bucket_index=0
    local -a job_pids=()
    
    for bucket_uri in "${buckets[@]}"; do
        bucket_index=$((bucket_index + 1))
        
        # Start bucket processing in background
        process_single_bucket "$project_id" "$bucket_uri" "$bucket_index" "$total_buckets" &
        job_pids+=($!)
        
        # If we've reached the max concurrent limit, wait for some to finish
        if [ ${#job_pids[@]} -ge $MAX_CONCURRENT_BUCKETS ]; then
            # Wait for the first few jobs to complete
            local jobs_to_wait=$((MAX_CONCURRENT_BUCKETS / 2))
            for ((i=0; i<jobs_to_wait; i++)); do
                if [ ${#job_pids[@]} -gt 0 ]; then
                    wait ${job_pids[0]} 2>/dev/null
                    job_pids=("${job_pids[@]:1}")  # Remove first element
                fi
            done
        fi
    done
    
    # Wait for all remaining jobs to complete
    echo "⏳ Waiting for remaining bucket scans to complete..."
    for pid in "${job_pids[@]}"; do
        wait "$pid" 2>/dev/null
    done
    
    echo "✅ All bucket scans completed for project: $project_id"
    
    # Collect results and update CSV
    local project_gcs_bytes=0
    
    for ((i=1; i<=total_buckets; i++)); do
        local result_file="$TEMP_DIR/bucket_${project_id}_${i}.result"
        
        if [ -f "$result_file" ]; then
            # Source the result file to get variables, but handle labels safely
            local bucket_name bucket_location storage_class created_time updated_time created_by labels bucket_bytes bucket_size_gb status
            
            # Read each line and extract values safely
            while IFS='=' read -r key value; do
                case "$key" in
                    "bucket_name") bucket_name="$value" ;;
                    "bucket_location") bucket_location="$value" ;;
                    "storage_class") storage_class="$value" ;;
                    "created_time") created_time="$value" ;;
                    "updated_time") updated_time="$value" ;;
                    "created_by") created_by="$value" ;;
                    "labels") labels="${value#\'}" ; labels="${labels%\'}" ;;  # Remove surrounding quotes
                    "bucket_bytes") bucket_bytes="$value" ;;
                    "bucket_size_gb") bucket_size_gb="$value" ;;
                    "status") status="$value" ;;
                esac
            done < "$result_file"
            
            # Add to CSV if we have valid data
            if [ "$status" != "processing" ]; then
                add_csv_row "$project_id" "GCS_Bucket" "$bucket_name" "$bucket_location" "$created_time" "$created_by" "$updated_time" "$storage_class" "$labels" "$bucket_size_gb" "$bucket_bytes"
                
                # Add to project total if it's a valid number
                if [[ "$bucket_bytes" =~ ^[0-9]+$ ]]; then
                    project_gcs_bytes=$(echo "$project_gcs_bytes + $bucket_bytes" | bc 2>/dev/null || echo "$project_gcs_bytes")
                fi
            fi
            
            rm -f "$result_file"
        fi
    done
    
    echo "$project_gcs_bytes"
}

# Enable cloudresourcemanager API to get project list
echo "🔧 Enabling Cloud Resource Manager API..."
gcloud services enable cloudresourcemanager.googleapis.com --quiet 2>/dev/null

echo "📋 Fetching all accessible projects..."
PROJECT_IDS_COMMAND="gcloud projects list --format='value(projectId)'"

# Get list of all projects first
ALL_PROJECTS=$(eval "$PROJECT_IDS_COMMAND")
PROJECT_COUNT=$(echo "$ALL_PROJECTS" | wc -l)

echo "✅ Found $PROJECT_COUNT accessible projects:"
echo "----------------------------------------"
echo "$ALL_PROJECTS" | nl -w3 -s'. '
echo "----------------------------------------"
echo ""

# Interactive project selection
echo "🔧 Project Selection Options:"
echo "  [1] Audit ALL projects (default)"
echo "  [2] Select specific projects manually"
echo ""
read -p "Enter your choice (1 or 2): " selection_choice

SELECTED_PROJECTS=""
if [ "$selection_choice" = "2" ]; then
    echo ""
    echo "📋 Available projects:"
    echo "----------------------------------------"
    echo "$ALL_PROJECTS" | nl -w3 -s'. '
    echo "----------------------------------------"
    echo ""
    echo "Enter project numbers to audit (space or comma separated):"
    echo "Examples: '1 3 5' or '1,3,5' or '1-5' for range"
    read -p "Project numbers: " project_numbers
    
    if [ -n "$project_numbers" ]; then
        # Convert input to array of numbers
        # Handle different input formats: spaces, commas, ranges
        project_numbers=$(echo "$project_numbers" | tr ',' ' ')
        
        # Process ranges (e.g., 1-5)
        expanded_numbers=""
        for num_or_range in $project_numbers; do
            if [[ "$num_or_range" == *"-"* ]]; then
                # Handle range
                start=$(echo "$num_or_range" | cut -d'-' -f1)
                end=$(echo "$num_or_range" | cut -d'-' -f2)
                if [[ "$start" =~ ^[0-9]+$ ]] && [[ "$end" =~ ^[0-9]+$ ]]; then
                    for ((i=start; i<=end; i++)); do
                        expanded_numbers="$expanded_numbers $i"
                    done
                fi
            else
                # Single number
                if [[ "$num_or_range" =~ ^[0-9]+$ ]]; then
                    expanded_numbers="$expanded_numbers $num_or_range"
                fi
            fi
        done
        
        # Get selected projects
        for num in $expanded_numbers; do
            if [ "$num" -ge 1 ] && [ "$num" -le "$PROJECT_COUNT" ]; then
                selected_project=$(echo "$ALL_PROJECTS" | sed -n "${num}p")
                if [ -n "$selected_project" ]; then
                    SELECTED_PROJECTS="$SELECTED_PROJECTS$selected_project"$'\n'
                fi
            else
                echo "⚠️  Warning: Project number $num is out of range (1-$PROJECT_COUNT)"
            fi
        done
        
        # Remove trailing newline
        SELECTED_PROJECTS=$(echo "$SELECTED_PROJECTS" | sed '/^$/d')
        
        if [ -n "$SELECTED_PROJECTS" ]; then
            selected_count=$(echo "$SELECTED_PROJECTS" | wc -l)
            echo ""
            echo "✅ Selected $selected_count projects for audit:"
            echo "----------------------------------------"
            echo "$SELECTED_PROJECTS" | nl -w3 -s'. '
            echo "----------------------------------------"
        else
            echo "❌ No valid projects selected. Exiting."
            exit 1
        fi
    else
        echo "❌ No project numbers provided. Exiting."
        exit 1
    fi
else
    # Default: use all projects
    SELECTED_PROJECTS="$ALL_PROJECTS"
    echo "✅ Will audit ALL $PROJECT_COUNT projects"
fi

echo ""
read -p "Press Enter to continue with the audit..."

# Display header
printf "\n%-40s %15s %15s %15s\n" "PROJECT ID" "BUCKETS (TB)" "DISKS (TB)" "FILESTORE (TB)"
echo "================================================================================================"

# Use the selected projects list
echo "$SELECTED_PROJECTS" | while read -r project_id; do
    if [ -z "$project_id" ]; then
        continue
    fi
    
    echo ""
    echo "🔍 Processing project: $project_id"
    echo "=================================================================="
    
    # Set current project
    gcloud config set project "$project_id" --quiet
    
    # Enable necessary APIs
    echo "🔧 Enabling required APIs for project: $project_id"
    gcloud services enable \
        compute.googleapis.com \
        storage.googleapis.com \
        file.googleapis.com \
        --project="$project_id" --quiet 2>/dev/null
    
    # Short sleep to prevent race conditions
    sleep 3
    
    # Initialize project totals
    project_pd_bytes=0
    project_filestore_bytes=0
    
    # --- Process GCS Buckets (Parallelized) ---
    echo ""
    echo "📦 Processing GCS Buckets for project: $project_id (Parallel Mode)"
    echo "----------------------------------------"
    
    BUCKET_LIST=$(gcloud storage ls --project="$project_id" 2>/dev/null | grep "gs://")
    
    # Process buckets in parallel and get total bytes
    project_gcs_bytes=$(process_buckets_parallel "$project_id" "$BUCKET_LIST")
    
    # --- Process Persistent Disks ---
    echo ""
    echo "💿 Processing Persistent Disks for project: $project_id"
    echo "----------------------------------------"
    
    DISK_OUTPUT=$(gcloud compute disks list --project="$project_id" --format=json 2>/dev/null)
    
    if [ -n "$DISK_OUTPUT" ] && [ "$DISK_OUTPUT" != "[]" ]; then
        TOTAL_DISKS=$(echo "$DISK_OUTPUT" | jq '. | length' 2>/dev/null || echo "0")
        echo "Found $TOTAL_DISKS persistent disks to analyze..."
        
        DISK_COUNTER=0
        
        # Process each disk
        while IFS= read -r disk_json; do
            if [ -n "$disk_json" ] && [ "$disk_json" != "null" ]; then
                DISK_COUNTER=$((DISK_COUNTER + 1))
                
                # Extract basic disk information
                disk_name=$(echo "$disk_json" | jq -r '.name')
                disk_zone=$(echo "$disk_json" | jq -r '.zone' | sed 's|.*/||')
                disk_size_gb=$(echo "$disk_json" | jq -r '.sizeGb')
                disk_type=$(echo "$disk_json" | jq -r '.type' | sed 's|.*/||')
                disk_status=$(echo "$disk_json" | jq -r '.status')
                created_time=$(echo "$disk_json" | jq -r '.creationTimestamp')
                
                echo "[$DISK_COUNTER/$TOTAL_DISKS] Processing disk: $disk_name ($disk_size_gb GB)"
                
                # Convert GB to bytes first
                disk_bytes=$(echo "$disk_size_gb * 1073741824" | bc 2>/dev/null || echo "0")
                
                # Get detailed disk description
                disk_detail_output=$(mktemp)
                disk_detail_error=$(mktemp)
                
                gcloud compute disks describe "$disk_name" --zone="$disk_zone" --project="$project_id" --format=json > "$disk_detail_output" 2> "$disk_detail_error"
                detail_exit_code=$?
                
                # Initialize metadata
                created_by="unknown"
                last_attach_time="unknown"
                labels="none"
                
                if [ $detail_exit_code -eq 0 ] && [ -s "$disk_detail_output" ]; then
                    # Extract additional metadata
                    last_attach_time=$(jq -r '.lastAttachTimestamp // "never"' "$disk_detail_output" 2>/dev/null || echo "never")
                    
                    # Extract creator/owner information
                    created_by=$(jq -r '.createdBy // .owner.entity // .owner.entityId // "unknown"' "$disk_detail_output" 2>/dev/null || echo "unknown")
                    if [ "$created_by" = "unknown" ]; then
                        # Try to extract from selfLink or other fields
                        created_by=$(jq -r '.selfLink | split("/") | .[6] // "unknown"' "$disk_detail_output" 2>/dev/null || echo "unknown")
                    fi
                    
                    # Check labels for creator info if still unknown
                    if [ "$created_by" = "unknown" ]; then
                        created_by=$(jq -r '.labels["created-by"] // .labels.createdBy // .labels.creator // "unknown"' "$disk_detail_output" 2>/dev/null || echo "unknown")
                    fi
                    
                    # Extract labels
                    labels_json=$(jq -r '.labels // {}' "$disk_detail_output" 2>/dev/null || echo "{}")
                    if [ "$labels_json" != "{}" ] && [ "$labels_json" != "null" ]; then
                        labels=$(echo "$labels_json" | jq -r 'to_entries[] | "\(.key)=\(.value)"' 2>/dev/null | paste -sd "; " - || echo "none")
                    else
                        labels="none"
                    fi
                    
                    echo "  ✓ Metadata: $disk_zone | $disk_type | $created_by"
                fi
                
                # Add to CSV
                add_csv_row "$project_id" "Persistent_Disk" "$disk_name" "$disk_zone" "$created_time" "$created_by" "$last_attach_time" "$disk_type" "$labels" "$disk_size_gb" "$disk_bytes"
                
                # Add to project total
                project_pd_bytes=$(echo "$project_pd_bytes + $disk_bytes" | bc 2>/dev/null || echo "$project_pd_bytes")
                
                rm -f "$disk_detail_output" "$disk_detail_error"
            fi
        done < <(echo "$DISK_OUTPUT" | jq -c '.[]')
        
    else
        echo "No persistent disks found in project: $project_id"
    fi
    
    # --- Process Filestore Instances ---
    echo ""
    echo "📁 Processing Filestore for project: $project_id"
    echo "----------------------------------------"
    
    FS_OUTPUT_RAW=$(gcloud filestore instances list --project="$project_id" --format=json 2>&1)
    
    if echo "$FS_OUTPUT_RAW" | jq . >/dev/null 2>&1; then
        FILESTORE_TOTAL_GB=$(echo "$FS_OUTPUT_RAW" | jq -r '[.[] | .fileShares[]?.capacityGb // 0] | map(tonumber) | add // 0' 2>/dev/null || echo "0")
        
        if [ "$FILESTORE_TOTAL_GB" != "null" ] && [ "$FILESTORE_TOTAL_GB" -gt 0 ]; then
            echo "Filestore instances found with total capacity: $FILESTORE_TOTAL_GB GB"
            
            # Convert GB to bytes for consistency
            FILESTORE_TOTAL_BYTES_ACTUAL=$(echo "$FILESTORE_TOTAL_GB * 1073741824" | bc 2>/dev/null || echo "0")
            project_filestore_bytes=$FILESTORE_TOTAL_BYTES_ACTUAL
            
            # Add each Filestore instance to CSV
            echo "$FS_OUTPUT_RAW" | jq -c '.[]' | while read -r fs_instance; do
                if [ -n "$fs_instance" ] && [ "$fs_instance" != "null" ]; then
                    # Extract instance metadata
                    fs_name=$(echo "$fs_instance" | jq -r '.name // "unknown"')
                    fs_location=$(echo "$fs_instance" | jq -r '.networks[0].zones[0] // .location // "unknown"')
                    fs_tier=$(echo "$fs_instance" | jq -r '.tier // "unknown"')
                    fs_created=$(echo "$fs_instance" | jq -r '.createTime // "unknown"')
                    fs_capacity_gb=$(echo "$fs_instance" | jq -r '.fileShares[0].capacityGb // 0')
                    
                    # Ensure we have a valid number for capacity
                    if [[ "$fs_capacity_gb" =~ ^[0-9]+$ ]]; then
                        fs_capacity_bytes=$(echo "$fs_capacity_gb * 1073741824" | bc 2>/dev/null || echo "0")
                    else
                        fs_capacity_gb="0"
                        fs_capacity_bytes="0"
                    fi
                    
                    # Extract labels
                    fs_labels_json=$(echo "$fs_instance" | jq -r '.labels // {}')
                    if [ "$fs_labels_json" != "{}" ] && [ "$fs_labels_json" != "null" ]; then
                        fs_labels=$(echo "$fs_labels_json" | jq -r 'to_entries[] | "\(.key)=\(.value)"' 2>/dev/null | paste -sd "; " - || echo "none")
                    else
                        fs_labels="none"
                    fi
                    
                    echo "  ✓ Instance: $fs_name | $fs_capacity_gb GB | $fs_tier"
                    
                    # Add to CSV
                    add_csv_row "$project_id" "Filestore" "$fs_name" "$fs_location" "$fs_created" "unknown" "unknown" "$fs_tier" "$fs_labels" "$fs_capacity_gb" "$fs_capacity_bytes"
                fi
            done
        else
            echo "No Filestore instances found in project: $project_id"
        fi
    else
        echo "Could not query Filestore for project: $project_id (API may be disabled)"
    fi
    
    # Calculate project totals in TB for display
    project_gcs_tb=$(echo "scale=2; $project_gcs_bytes / 1099511627776" | bc -l 2>/dev/null || echo "0.00")
    project_pd_tb=$(echo "scale=2; $project_pd_bytes / 1099511627776" | bc -l 2>/dev/null || echo "0.00")
    project_filestore_tb=$(echo "scale=2; $project_filestore_bytes / 1099511627776" | bc -l 2>/dev/null || echo "0.00")
    
    # Add to global totals
    TOTAL_GCS_BYTES=$(echo "$TOTAL_GCS_BYTES + $project_gcs_bytes" | bc 2>/dev/null || echo "$TOTAL_GCS_BYTES")
    TOTAL_PD_BYTES=$(echo "$TOTAL_PD_BYTES + $project_pd_bytes" | bc 2>/dev/null || echo "$TOTAL_PD_BYTES")
    TOTAL_FILESTORE_BYTES=$(echo "$TOTAL_FILESTORE_BYTES + $project_filestore_bytes" | bc 2>/dev/null || echo "$TOTAL_FILESTORE_BYTES")
    
    # Display project summary
    printf "%-40s %15.2f %15.2f %15.2f\n" "$project_id" "$project_gcs_tb" "$project_pd_tb" "$project_filestore_tb"
    
done

echo "================================================================================================"
echo ""

# Calculate final totals
TOTAL_GCS_TB=$(echo "scale=2; $TOTAL_GCS_BYTES / 1099511627776" | bc -l 2>/dev/null || echo "0.00")
TOTAL_PD_TB=$(echo "scale=2; $TOTAL_PD_BYTES / 1099511627776" | bc -l 2>/dev/null || echo "0.00")
TOTAL_FILESTORE_TB=$(echo "scale=2; $TOTAL_FILESTORE_BYTES / 1099511627776" | bc -l 2>/dev/null || echo "0.00")
GRAND_TOTAL_TB=$(echo "$TOTAL_GCS_TB + $TOTAL_PD_TB + $TOTAL_FILESTORE_TB" | bc -l 2>/dev/null || echo "0.00")

# Display final summary
echo "🎯 FINAL SUMMARY"
echo "================================================================================================"
printf "%-40s %15.2f %15.2f %15.2f\n" "TOTAL ACROSS ALL PROJECTS" "$TOTAL_GCS_TB" "$TOTAL_PD_TB" "$TOTAL_FILESTORE_TB"
echo "================================================================================================"
printf "%-40s %15.2f TB\n" "GRAND TOTAL STORAGE" "$GRAND_TOTAL_TB"
echo "================================================================================================"
echo ""

# Performance and file information
AUDIT_END_TIME=$(date +%s)
AUDIT_DURATION=$((AUDIT_END_TIME - TIMESTAMP))
AUDIT_DURATION_MIN=$(echo "scale=1; $AUDIT_DURATION / 60" | bc -l 2>/dev/null || echo "0.0")

echo "⏱️  PERFORMANCE METRICS"
echo "================================================================================================"
echo "Audit Duration: ${AUDIT_DURATION} seconds (${AUDIT_DURATION_MIN} minutes)"
echo "Projects Processed: $(echo "$SELECTED_PROJECTS" | wc -l)"
echo "Parallelization Used: Up to $MAX_CONCURRENT_BUCKETS concurrent bucket scans"
echo ""

echo "📊 OUTPUT FILES"
echo "================================================================================================"
echo "Detailed Log: $LOG_FILE"
echo "CSV Inventory: $CSV_FILE"
echo ""

# CSV file statistics
if [ -f "$CSV_FILE" ]; then
    CSV_LINES=$(wc -l < "$CSV_FILE" 2>/dev/null || echo "0")
    CSV_SIZE=$(du -h "$CSV_FILE" 2>/dev/null | cut -f1 || echo "unknown")
    echo "CSV Statistics:"
    echo "  - Total rows: $((CSV_LINES - 1)) (excluding header)"
    echo "  - File size: $CSV_SIZE"
    echo ""
fi

echo "✅ GCP Multi-Project Storage Audit Complete!"
echo "================================================================================================"

# Show top storage consumers if we have data
if [ -f "$CSV_FILE" ] && [ "$CSV_LINES" -gt 1 ]; then
    echo ""
    echo "🔝 TOP 10 STORAGE CONSUMERS"
    echo "================================================================================================"
    
    # Skip header and sort by storage size in bytes (column 11), show top 10
    tail -n +2 "$CSV_FILE" 2>/dev/null | sort -t',' -k11 -nr 2>/dev/null | head -10 | while IFS=',' read -r project resource_type name location created_time created_by last_updated type labels size_gb size_bytes; do
        # Clean up the fields (remove quotes if present)
        project=$(echo "$project" | sed 's/"//g')
        resource_type=$(echo "$resource_type" | sed 's/"//g')
        name=$(echo "$name" | sed 's/"//g')
        size_gb=$(echo "$size_gb" | sed 's/"//g')
        
        # Convert to human readable if it's a valid number
        if [[ "$size_gb" =~ ^[0-9]*\.?[0-9]+$ ]] && [ "$(echo "$size_gb > 0" | bc 2>/dev/null || echo "0")" -eq 1 ]; then
            if [ "$(echo "$size_gb >= 1024" | bc 2>/dev/null || echo "0")" -eq 1 ]; then
                size_tb=$(echo "scale=2; $size_gb / 1024" | bc -l 2>/dev/null || echo "0")
                size_display="${size_tb} TB"
            else
                size_display="${size_gb} GB"
            fi
        else
            size_display="$size_gb GB"
        fi
        
        printf "%-25s %-15s %-30s %15s\n" "$project" "$resource_type" "$(echo "$name" | cut -c1-30)" "$size_display"
    done
    echo "================================================================================================"
fi

echo ""
echo "💡 TIPS FOR OPTIMIZATION"
echo "================================================================================================"
echo "1. Review the CSV file for detailed analysis: $CSV_FILE"
echo "2. Look for unused or oversized resources in the top consumers list"
echo "3. Consider lifecycle policies for GCS buckets with old data"
echo "4. Check for unattached persistent disks that can be deleted"
echo "5. Verify Filestore instances are being actively used"
echo "================================================================================================"

# Restore stdout/stderr
exec 1>&3 2>&4
exec 3>&- 4>&- 