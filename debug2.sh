#!/usr/bin/env bash

# --- GCP Storage Debugging Script (v11 - Enhanced with Metadata) ---
# This script tests GCS, Persistent Disks, and Filestore with metadata collection

# --- Configuration ---
PROJECT_ID_GCS="sdo-ml"
PROJECT_ID_FS="hl-compute"
TIMESTAMP=$(date +%s)
LOG_FILE="gcp_debug_log_enhanced_${TIMESTAMP}.txt"
CSV_FILE="gcp_storage_inventory_${TIMESTAMP}.csv"

# --- Setup Logging ---
exec 3>&1 4>&2
exec > >(tee -a "$LOG_FILE") 2>&1
# Note: set -x is disabled for clean progress display

echo "--- Starting Enhanced Debug Script ---"

# Initialize CSV file with headers
echo "GCP_Project,Resource_Type,Resource_Name,Location_Zone,Creation_Time,Created_By,Last_Updated,Type,Labels,Storage_Size_GB,Storage_Size_Bytes" > "$CSV_FILE"
echo "CSV inventory file initialized: $CSV_FILE"

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

# Function to add row to CSV
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
    
    echo "$project,$resource_type,$resource_name,$location_zone,$creation_time,$created_by,$last_updated,$type,$labels,$storage_size_gb,$storage_size_bytes" >> "$CSV_FILE"
}

# Check if required tools are available
command -v gcloud >/dev/null 2>&1 || { echo "Error: gcloud CLI not found"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq not found"; exit 1; }
command -v bc >/dev/null 2>&1 || { echo "Error: bc not found"; exit 1; }

# --- Part 1: Debug GCS for 'sdo-ml' with metadata collection ---
echo -e "\n\n--- DEBUG: GCS for project: $PROJECT_ID_GCS ---"
gcloud config set project "$PROJECT_ID_GCS"
gcloud services enable storage.googleapis.com --project="$PROJECT_ID_GCS"
sleep 5

echo "--- Step 1.1: Listing buckets ---"
BUCKET_LIST=$(gcloud storage ls --project="$PROJECT_ID_GCS" 2>/dev/null)
if [ -z "$BUCKET_LIST" ]; then
    echo "No buckets found or error accessing buckets"
    exit 1
fi

echo "--- Buckets found: ---"
echo "$BUCKET_LIST"

echo -e "\n--- Step 1.2: Collecting bucket metadata and calculating sizes ---"
PROJECT_GCS_BYTES=0

# Fix: Use a temporary file to accumulate the total since pipe creates subshell
TEMP_TOTAL=$(mktemp)
echo "0" > "$TEMP_TOTAL"

# Count total buckets for progress tracking
TOTAL_BUCKETS=$(echo "$BUCKET_LIST" | grep -c "gs://")
CURRENT_BUCKET=0

echo "Found $TOTAL_BUCKETS buckets to process..."
echo ""

# Process buckets using process substitution to avoid subshell issues
while IFS= read -r bucket_uri; do
    if [ -n "$bucket_uri" ]; then
        CURRENT_BUCKET=$((CURRENT_BUCKET + 1))
        echo "[$CURRENT_BUCKET/$TOTAL_BUCKETS] Processing bucket: $bucket_uri"
        
        # --- NEW: Collect bucket metadata ---
        echo "  📋 Collecting bucket metadata..."
        bucket_metadata_output=$(mktemp)
        bucket_metadata_error=$(mktemp)
        
        # Initialize metadata variables with defaults
        bucket_name="$bucket_uri"
        bucket_location="unknown"
        storage_class="unknown"
        created_time="unknown"
        updated_time="unknown"
        created_by="unknown"
        labels="none"
        
        gcloud storage buckets describe "$bucket_uri" --format=json > "$bucket_metadata_output" 2> "$bucket_metadata_error"
        metadata_exit_code=$?
        
        if [ $metadata_exit_code -eq 0 ] && [ -s "$bucket_metadata_output" ]; then
            echo "  ✓ Bucket metadata collected successfully"
            
            # Debug: Show the actual JSON structure we're working with
            echo "  DEBUG: Raw JSON content (first 500 chars):"
            head -c 500 "$bucket_metadata_output"
            echo ""
            echo "  DEBUG: Available top-level keys:"
            jq -r 'keys[]' "$bucket_metadata_output" 2>/dev/null | head -10
            
            # Try different field names that might exist in the JSON
            bucket_name=$(jq -r '.name // .id // "unknown"' "$bucket_metadata_output" 2>/dev/null)
            echo "  DEBUG: bucket_name = '$bucket_name'"
            
            bucket_location=$(jq -r '.location // .locationType // "unknown"' "$bucket_metadata_output" 2>/dev/null)
            echo "  DEBUG: bucket_location = '$bucket_location'"
            
            # Try multiple possible field names for storage class (GCS uses default_storage_class, others might use storageClass)
            storage_class=$(jq -r '.default_storage_class // .storageClass // .defaultStorageClass // .storage_class // "unknown"' "$bucket_metadata_output" 2>/dev/null)
            echo "  DEBUG: storage_class = '$storage_class'"
            
            # Try multiple timestamp field names (GCS uses creation_time, others might use timeCreated)
            created_time=$(jq -r '.creation_time // .timeCreated // .createTime // .created // .creationTimestamp // "unknown"' "$bucket_metadata_output" 2>/dev/null)
            echo "  DEBUG: created_time = '$created_time'"
            
            # Try multiple update timestamp field names (GCS uses update_time, others might use updated)
            updated_time=$(jq -r '.update_time // .updated // .timeUpdated // .updateTime // .lastModified // "unknown"' "$bucket_metadata_output" 2>/dev/null)
            echo "  DEBUG: updated_time = '$updated_time'"
            
            versioning=$(jq -r '.versioning.enabled // false' "$bucket_metadata_output" 2>/dev/null)
            
            # Extract creator information (try multiple possible fields, including from labels)
            created_by=$(jq -r '.owner.entity // .owner.entityId // .createdBy // .created_by // "unknown"' "$bucket_metadata_output" 2>/dev/null)
            
            # For GCS buckets, check if creator info is in labels
            if [ "$created_by" = "unknown" ]; then
                created_by=$(jq -r '.labels["created-by"] // .labels.createdBy // .labels.creator // "unknown"' "$bucket_metadata_output" 2>/dev/null)
            fi
            echo "  DEBUG: created_by = '$created_by'"
            
            # Extract labels
            labels_json=$(jq -r '.labels // {}' "$bucket_metadata_output" 2>/dev/null)
            if [ "$labels_json" != "{}" ] && [ "$labels_json" != "null" ]; then
                labels=$(echo "$labels_json" | jq -r 'to_entries | map("\(.key)=\(.value)") | join("; ")' 2>/dev/null)
            else
                labels="none"
            fi
            echo "  DEBUG: labels = '$labels'"
            
            echo "    Name: $bucket_name"
            echo "    Location: $bucket_location"
            echo "    Storage Class: $storage_class"
            echo "    Created: $created_time"
            echo "    Created By: $created_by"
            echo "    Last Updated: $updated_time"
            echo "    Versioning Enabled: $versioning"
            
            # Check for lifecycle policies
            lifecycle_rules=$(jq -r '.lifecycle.rule // [] | length' "$bucket_metadata_output" 2>/dev/null)
            if [ "$lifecycle_rules" -gt 0 ]; then
                echo "    Lifecycle Rules: $lifecycle_rules configured"
            fi
            
            # Check for encryption
            encryption_type=$(jq -r '.encryption.defaultKmsKeyName // "Google-managed"' "$bucket_metadata_output" 2>/dev/null)
            if [ "$encryption_type" != "Google-managed" ]; then
                echo "    Encryption: Custom KMS key"
            else
                echo "    Encryption: Google-managed"
            fi
            
            if [ -n "$labels" ] && [ "$labels" != "none" ]; then
                echo "    Labels: $labels"
            fi
            
        else
            echo "  ⚠ Could not collect bucket metadata"
            if [ -s "$bucket_metadata_error" ]; then
                echo "    Error: $(cat "$bucket_metadata_error")"
            fi
        fi
        
        rm -f "$bucket_metadata_output" "$bucket_metadata_error"
        
        # Create a cleaner progress indicator function
        show_progress() {
            local project=$1
            local bucket=$2
            local start_time=$(date +%s)
            
            while true; do
                local current_time=$(date +%s)
                local elapsed=$((current_time - start_time))
                
                # Format elapsed time nicely
                local elapsed_display
                if [ $elapsed -ge 3600 ]; then
                    elapsed_display="${elapsed}s ($(($elapsed/3600))h$(((elapsed%3600)/60))m)"
                elif [ $elapsed -ge 60 ]; then
                    elapsed_display="${elapsed}s ($(($elapsed/60))m$(($elapsed%60))s)"
                else
                    elapsed_display="${elapsed}s"
                fi
                
                # Clean, informative progress line
                printf "\r  📊 Project: %s | Bucket: %s | Elapsed: %s | Status: Scanning...     " \
                    "$project" "$(basename "$bucket")" "$elapsed_display" >&3
                
                sleep 2
                
                # Check if we should stop (parent will kill us)
                if [ ! -f "/tmp/progress_$bucket_safe" ]; then
                    break
                fi
            done
            printf "\r" >&3
        }
        
        # Start the du command
        echo "  📊 Starting size calculation..."
        
        # Create safe filename for progress control
        bucket_safe=$(echo "$bucket_uri" | tr '/' '_' | tr ':' '_')
        touch "/tmp/progress_$bucket_safe"
        
        # Run gcloud storage du with better error handling
        temp_output=$(mktemp)
        temp_error=$(mktemp)
        
        # Run the command with explicit stdout/stderr separation
        gcloud storage du --summarize "$bucket_uri" > "$temp_output" 2> "$temp_error" &
        du_pid=$!
        
        # Show progress while scanning
        show_progress "$PROJECT_ID_GCS" "$bucket_uri" &
        progress_pid=$!
        
        # Wait for the du command to complete
        wait $du_pid
        du_exit_code=$?
        
        # Stop the progress indicator
        rm -f "/tmp/progress_$bucket_safe"
        kill $progress_pid 2>/dev/null
        wait $progress_pid 2>/dev/null
        
        # Clear the progress line
        printf "\r                                                                    \r" >&3
        
        if [ $du_exit_code -eq 0 ]; then
            bucket_size_output=$(cat "$temp_output")
            
            # IMPROVED PARSING LOGIC
            bucket_bytes=""
            
            if [ -n "$bucket_size_output" ]; then
                # Try different parsing approaches
                bucket_bytes=$(echo "$bucket_size_output" | grep -E "^[0-9]+" | tail -1 | awk '{print $1}' 2>/dev/null)
                
                if [[ ! "$bucket_bytes" =~ ^[0-9]+$ ]]; then
                    bucket_bytes=$(echo "$bucket_size_output" | grep -oE '[0-9]+' | tail -1 2>/dev/null)
                fi
                
                if [[ ! "$bucket_bytes" =~ ^[0-9]+$ ]]; then
                    bucket_bytes=$(echo "$bucket_size_output" | grep -i "total" | grep -oE '[0-9]+' | tail -1 2>/dev/null)
                fi
                
                if [[ ! "$bucket_bytes" =~ ^[0-9]+$ ]]; then
                    bucket_bytes=$(echo "$bucket_size_output" | awk '/^[0-9]/ {bytes=$1} END {print bytes}' 2>/dev/null)
                fi
            fi
            
            # Validate and process the result
            if [[ "$bucket_bytes" =~ ^[0-9]+$ ]] && [ "$bucket_bytes" -gt 0 ]; then
                # Convert to human readable format for display
                if [ "$bucket_bytes" -gt 1099511627776 ]; then
                    human_size=$(echo "scale=2; $bucket_bytes / 1099511627776" | bc -l)
                    size_unit="TB"
                elif [ "$bucket_bytes" -gt 1073741824 ]; then
                    human_size=$(echo "scale=2; $bucket_bytes / 1073741824" | bc -l)
                    size_unit="GB"
                elif [ "$bucket_bytes" -gt 1048576 ]; then
                    human_size=$(echo "scale=2; $bucket_bytes / 1048576" | bc -l)
                    size_unit="MB"
                else
                    human_size=$bucket_bytes
                    size_unit="bytes"
                fi
                
                echo "  ✓ Size: $human_size $size_unit ($bucket_bytes bytes)"
                
                # Calculate size in GB for CSV
                bucket_size_gb=$(echo "scale=6; $bucket_bytes / 1073741824" | bc -l)
                
                # Add to CSV using the metadata variables that are now in scope
                add_csv_row "$PROJECT_ID_GCS" "GCS_Bucket" "$bucket_name" "$bucket_location" "$created_time" "$created_by" "$updated_time" "$storage_class" "$labels" "$bucket_size_gb" "$bucket_bytes"
                
                # Update running total
                current_total=$(cat "$TEMP_TOTAL")
                new_total=$(echo "$current_total + $bucket_bytes" | bc)
                echo "$new_total" > "$TEMP_TOTAL"
                
                # Show running total
                if [ "$new_total" -gt 1099511627776 ]; then
                    running_tb=$(echo "scale=2; $new_total / 1099511627776" | bc -l)
                    echo "  Running total: ${running_tb} TB"
                elif [ "$new_total" -gt 1073741824 ]; then
                    running_gb=$(echo "scale=2; $new_total / 1073741824" | bc -l)
                    echo "  Running total: ${running_gb} GB"
                fi
            else
                echo "  ✓ Size: 0 bytes (empty bucket or parse error)"
                
                # Still add to CSV with 0 size, using the metadata variables
                add_csv_row "$PROJECT_ID_GCS" "GCS_Bucket" "$bucket_name" "$bucket_location" "$created_time" "$created_by" "$updated_time" "$storage_class" "$labels" "0" "0"
            fi
        else
            echo "  ✗ Error getting size for $bucket_uri (exit code: $du_exit_code)"
            if [ -s "$temp_error" ]; then
                echo "  Error details: $(cat "$temp_error")"
            fi
            
            # Still add to CSV with error info, using the metadata variables
            add_csv_row "$PROJECT_ID_GCS" "GCS_Bucket" "$bucket_name" "$bucket_location" "$created_time" "$created_by" "$updated_time" "$storage_class" "$labels" "ERROR" "ERROR"
        fi
        
        # Clean up temp files
        rm -f "$temp_output" "$temp_error"
        echo ""
    fi
done < <(echo "$BUCKET_LIST" | grep "gs://")

# Read the final total
PROJECT_GCS_BYTES=$(cat "$TEMP_TOTAL")
rm -f "$TEMP_TOTAL"

echo "--- Total calculated GCS size (Bytes): ---"
echo "$PROJECT_GCS_BYTES"

if [ "$PROJECT_GCS_BYTES" -gt 0 ]; then
    GCS_TB=$(echo "scale=2; $PROJECT_GCS_BYTES / 1024 / 1024 / 1024 / 1024" | bc -l)
    echo "--- Total calculated GCS size (TB): $GCS_TB ---"
else
    echo "--- No storage usage calculated ---"
fi

# --- NEW: Part 1.5: Persistent Disks Analysis ---
echo -e "\n\n--- DEBUG: Persistent Disks for project: $PROJECT_ID_GCS ---"
gcloud services enable compute.googleapis.com --project="$PROJECT_ID_GCS"
sleep 5

echo "--- Step 1.5.1: Listing persistent disks ---"
DISK_OUTPUT=$(gcloud compute disks list --project="$PROJECT_ID_GCS" --format=json 2>/dev/null)

if [ -n "$DISK_OUTPUT" ] && [ "$DISK_OUTPUT" != "[]" ]; then
    echo "--- Persistent disks found ---"
    
    # Count disks for progress
    TOTAL_DISKS=$(echo "$DISK_OUTPUT" | jq '. | length' 2>/dev/null || echo "0")
    echo "Found $TOTAL_DISKS persistent disks to analyze..."
    echo ""
    
    # Use temporary file to accumulate disk bytes (same approach as GCS)
    TEMP_DISK_TOTAL=$(mktemp)
    echo "0" > "$TEMP_DISK_TOTAL"
    
    DISK_COUNTER=0
    
    # Process each disk using while loop with process substitution to avoid subshell
    while IFS= read -r disk_json; do
        if [ -n "$disk_json" ] && [ "$disk_json" != "null" ]; then
            DISK_COUNTER=$((DISK_COUNTER + 1))
            
            # Extract disk information
            disk_name=$(echo "$disk_json" | jq -r '.name')
            disk_zone=$(echo "$disk_json" | jq -r '.zone' | sed 's|.*/||')
            disk_size_gb=$(echo "$disk_json" | jq -r '.sizeGb')
            disk_type=$(echo "$disk_json" | jq -r '.type' | sed 's|.*/||')
            disk_status=$(echo "$disk_json" | jq -r '.status')
            created_time=$(echo "$disk_json" | jq -r '.creationTimestamp')
            
            echo "[$DISK_COUNTER/$TOTAL_DISKS] Analyzing disk: $disk_name"
            echo "  📋 Collecting detailed disk metadata..."
            
            # Convert GB to bytes first
            disk_bytes=$(echo "$disk_size_gb * 1024 * 1024 * 1024" | bc)
            
            # Get detailed disk description
            disk_detail_output=$(mktemp)
            disk_detail_error=$(mktemp)
            
            gcloud compute disks describe "$disk_name" --zone="$disk_zone" --project="$PROJECT_ID_GCS" --format=json > "$disk_detail_output" 2> "$disk_detail_error"
            detail_exit_code=$?
            
            if [ $detail_exit_code -eq 0 ] && [ -s "$disk_detail_output" ]; then
                echo "  ✓ Disk metadata collected successfully"
                
                # Extract additional metadata
                source_image=$(jq -r '.sourceImage // "none"' "$disk_detail_output" 2>/dev/null | sed 's|.*/||')
                source_snapshot=$(jq -r '.sourceSnapshot // "none"' "$disk_detail_output" 2>/dev/null | sed 's|.*/||')
                last_attach_time=$(jq -r '.lastAttachTimestamp // "never"' "$disk_detail_output" 2>/dev/null)
                last_detach_time=$(jq -r '.lastDetachTimestamp // "never"' "$disk_detail_output" 2>/dev/null)
                users=$(jq -r '.users[]? // empty' "$disk_detail_output" 2>/dev/null | sed 's|.*/||' | tr '\n' ', ' | sed 's/,$//')
                
                # Check for encryption
                encryption_key=$(jq -r '.diskEncryptionKey.kmsKeyName // "Google-managed"' "$disk_detail_output" 2>/dev/null)
                
                # Extract creator/owner information
                created_by_detail=$(jq -r '.createdBy // "unknown"' "$disk_detail_output" 2>/dev/null)
                if [ "$created_by_detail" = "unknown" ]; then
                    # Try to extract from selfLink or other fields
                    created_by_detail=$(jq -r '.selfLink | split("/") | .[6] // "unknown"' "$disk_detail_output" 2>/dev/null)
                fi
                
                # Extract labels
                labels_json=$(jq -r '.labels // {}' "$disk_detail_output" 2>/dev/null)
                if [ "$labels_json" != "{}" ] && [ "$labels_json" != "null" ]; then
                    labels=$(echo "$labels_json" | jq -r 'to_entries | map("\(.key)=\(.value)") | join("; ")' 2>/dev/null)
                else
                    labels="none"
                fi
                
                echo "    Name: $disk_name"
                echo "    Zone: $disk_zone"
                echo "    Size: $disk_size_gb GB"
                echo "    Type: $disk_type"
                echo "    Status: $disk_status"
                echo "    Created: $created_time"
                echo "    Created By: $created_by_detail"
                
                if [ "$source_image" != "none" ]; then
                    echo "    Source Image: $source_image"
                fi
                
                if [ "$source_snapshot" != "none" ]; then
                    echo "    Source Snapshot: $source_snapshot"
                fi
                
                if [ -n "$users" ]; then
                    echo "    Attached to: $users"
                else
                    echo "    Attached to: (none)"
                fi
                
                if [ "$last_attach_time" != "never" ]; then
                    echo "    Last Attached: $last_attach_time"
                fi
                
                if [ "$last_detach_time" != "never" ]; then
                    echo "    Last Detached: $last_detach_time"
                fi
                
                if [ "$encryption_key" != "Google-managed" ]; then
                    echo "    Encryption: Custom KMS key"
                else
                    echo "    Encryption: Google-managed"
                fi
                
                if [ -n "$labels" ] && [ "$labels" != "none" ]; then
                    echo "    Labels: $labels"
                fi
                
                # Add to CSV with detailed metadata
                add_csv_row "$PROJECT_ID_GCS" "Persistent_Disk" "$disk_name" "$disk_zone" "$created_time" "$created_by_detail" "$last_attach_time" "$disk_type" "$labels" "$disk_size_gb" "$disk_bytes"
                
            else
                echo "  ⚠ Could not collect detailed disk metadata"
                if [ -s "$disk_detail_error" ]; then
                    echo "    Error: $(cat "$disk_detail_error")"
                fi
                
                echo "  Basic info - Size: $disk_size_gb GB, Type: $disk_type, Status: $disk_status"
                
                # Add to CSV with basic metadata only
                add_csv_row "$PROJECT_ID_GCS" "Persistent_Disk" "$disk_name" "$disk_zone" "$created_time" "unknown" "unknown" "$disk_type" "none" "$disk_size_gb" "$disk_bytes"
            fi
            
            # Add to running total (using temp file)
            current_disk_total=$(cat "$TEMP_DISK_TOTAL")
            new_disk_total=$(echo "$current_disk_total + $disk_bytes" | bc)
            echo "$new_disk_total" > "$TEMP_DISK_TOTAL"
            
            # Show running total
            if [ "$new_disk_total" -gt 1099511627776 ]; then
                running_tb=$(echo "scale=2; $new_disk_total / 1099511627776" | bc -l)
                echo "  Running disk total: ${running_tb} TB"
            elif [ "$new_disk_total" -gt 1073741824 ]; then
                running_gb=$(echo "scale=2; $new_disk_total / 1073741824" | bc -l)
                echo "  Running disk total: ${running_gb} GB"
            fi
            
            rm -f "$disk_detail_output" "$disk_detail_error"
            echo ""
        fi
    done < <(echo "$DISK_OUTPUT" | jq -c '.[]')
    
    # Read the final disk total
    PROJECT_DISK_BYTES=$(cat "$TEMP_DISK_TOTAL")
    rm -f "$TEMP_DISK_TOTAL"
    
    echo "--- Total Persistent Disk Usage ---"
    if [ "$PROJECT_DISK_BYTES" -gt 0 ]; then
        DISK_TB=$(echo "scale=2; $PROJECT_DISK_BYTES / 1024 / 1024 / 1024 / 1024" | bc -l)
        DISK_GB=$(echo "scale=2; $PROJECT_DISK_BYTES / 1024 / 1024 / 1024" | bc -l)
        echo "Total Disk Size: $DISK_GB GB ($DISK_TB TB)"
        echo "Total Disk Size (Bytes): $PROJECT_DISK_BYTES"
    else
        echo "No persistent disk usage calculated"
    fi
else
    echo "--- No persistent disks found ---"
    PROJECT_DISK_BYTES=0
fi

# --- Part 2: Verify Filestore for 'hl-compute' ---
echo -e "\n\n--- VERIFY: Filestore for project: $PROJECT_ID_FS ---"
gcloud config set project "$PROJECT_ID_FS"

echo "--- Step 2.1: Capturing raw JSON output from gcloud ---"
FS_OUTPUT_RAW=$(gcloud filestore instances list --project="$PROJECT_ID_FS" --format=json 2>&1)
echo "--- Raw output received: ---"
echo "$FS_OUTPUT_RAW" | jq . 2>/dev/null || echo "Could not parse JSON output"

echo -e "\n--- Step 2.2: Processing Filestore instances ---"
if echo "$FS_OUTPUT_RAW" | jq . >/dev/null 2>&1; then
    # Parse Filestore instances and calculate total size
    FILESTORE_TOTAL_BYTES=$(echo "$FS_OUTPUT_RAW" | jq -r '[.[] | .fileShares[]?.capacityGb // 0] | map(tonumber) | add // 0')
    
    if [ "$FILESTORE_TOTAL_BYTES" != "null" ] && [ "$FILESTORE_TOTAL_BYTES" -gt 0 ]; then
        # Convert GB to bytes for consistency
        FILESTORE_TOTAL_BYTES_ACTUAL=$(echo "$FILESTORE_TOTAL_BYTES * 1024 * 1024 * 1024" | bc)
        FILESTORE_TB=$(echo "scale=2; $FILESTORE_TOTAL_BYTES / 1024" | bc -l)
        
        echo "--- Filestore instances found ---"
        echo "$FS_OUTPUT_RAW" | jq -r '.[] | "Instance: \(.name), Capacity: \(.fileShares[0].capacityGb // 0) GB, Tier: \(.tier), State: \(.state)"'
        echo "--- Total Filestore capacity: $FILESTORE_TOTAL_BYTES GB ($FILESTORE_TB TB) ---"
        echo "--- Total Filestore capacity (Bytes): $FILESTORE_TOTAL_BYTES_ACTUAL ---"
        
        # Add each Filestore instance to CSV
        echo "$FS_OUTPUT_RAW" | jq -c '.[]' | while read -r fs_instance; do
            if [ -n "$fs_instance" ] && [ "$fs_instance" != "null" ]; then
                # Extract instance metadata
                fs_name=$(echo "$fs_instance" | jq -r '.name // "unknown"')
                fs_location=$(echo "$fs_instance" | jq -r '.networks[0].zones[0] // .location // "unknown"')
                fs_tier=$(echo "$fs_instance" | jq -r '.tier // "unknown"')
                fs_state=$(echo "$fs_instance" | jq -r '.state // "unknown"')
                fs_created=$(echo "$fs_instance" | jq -r '.createTime // "unknown"')
                fs_capacity_gb=$(echo "$fs_instance" | jq -r '.fileShares[0].capacityGb // 0')
                
                # Ensure we have a valid number for capacity
                if [[ "$fs_capacity_gb" =~ ^[0-9]+$ ]]; then
                    fs_capacity_bytes=$(echo "$fs_capacity_gb * 1024 * 1024 * 1024" | bc)
                else
                    fs_capacity_gb="0"
                    fs_capacity_bytes="0"
                fi
                
                # Extract labels
                fs_labels_json=$(echo "$fs_instance" | jq -r '.labels // {}')
                if [ "$fs_labels_json" != "{}" ] && [ "$fs_labels_json" != "null" ]; then
                    fs_labels=$(echo "$fs_labels_json" | jq -r 'to_entries | map("\(.key)=\(.value)") | join("; ")' 2>/dev/null)
                else
                    fs_labels="none"
                fi
                
                # Add to CSV
                add_csv_row "$PROJECT_ID_FS" "Filestore" "$fs_name" "$fs_location" "$fs_created" "unknown" "unknown" "$fs_tier" "$fs_labels" "$fs_capacity_gb" "$fs_capacity_bytes"
            fi
        done
    else
        echo "--- No Filestore instances found or no capacity data ---"
    fi
else
    echo "--- Error: Could not parse Filestore output as JSON ---"
    echo "Raw output:"
    echo "$FS_OUTPUT_RAW"
fi

echo -e "\n=== FINAL SUMMARY ==="

# Ensure all variables have default values
PROJECT_GCS_BYTES=${PROJECT_GCS_BYTES:-0}
PROJECT_DISK_BYTES=${PROJECT_DISK_BYTES:-0}
FILESTORE_TOTAL_BYTES_ACTUAL=${FILESTORE_TOTAL_BYTES_ACTUAL:-0}

echo "GCS Storage (project: $PROJECT_ID_GCS):"
if [ "$PROJECT_GCS_BYTES" -gt 0 ] 2>/dev/null; then
    GCS_TB=$(echo "scale=2; $PROJECT_GCS_BYTES / 1024 / 1024 / 1024 / 1024" | bc -l)
    echo "  Total: $GCS_TB TB ($PROJECT_GCS_BYTES bytes)"
else
    echo "  Total: 0 TB"
fi

echo "Persistent Disks (project: $PROJECT_ID_GCS):"
if [ "$PROJECT_DISK_BYTES" -gt 0 ] 2>/dev/null; then
    DISK_TB=$(echo "scale=2; $PROJECT_DISK_BYTES / 1024 / 1024 / 1024 / 1024" | bc -l)
    echo "  Total: $DISK_TB TB ($PROJECT_DISK_BYTES bytes)"
else
    echo "  Total: 0 TB"
fi

echo "Filestore (project: $PROJECT_ID_FS):"
if [ "$FILESTORE_TOTAL_BYTES_ACTUAL" -gt 0 ] 2>/dev/null; then
    FILESTORE_TB=$(echo "scale=2; $FILESTORE_TOTAL_BYTES_ACTUAL / 1024 / 1024 / 1024 / 1024" | bc -l)
    echo "  Total: $FILESTORE_TB TB ($FILESTORE_TOTAL_BYTES_ACTUAL bytes)"
else
    echo "  Total: 0 TB"
fi

# Calculate grand total
GRAND_TOTAL=$(echo "$PROJECT_GCS_BYTES + $PROJECT_DISK_BYTES + $FILESTORE_TOTAL_BYTES_ACTUAL" | bc)
if [ "$GRAND_TOTAL" -gt 0 ] 2>/dev/null; then
    GRAND_TOTAL_TB=$(echo "scale=2; $GRAND_TOTAL / 1024 / 1024 / 1024 / 1024" | bc -l)
    echo ""
    echo "GRAND TOTAL ACROSS ALL STORAGE TYPES: $GRAND_TOTAL_TB TB ($GRAND_TOTAL bytes)"
else
    echo ""
    echo "GRAND TOTAL ACROSS ALL STORAGE TYPES: 0 TB"
fi

echo -e "\n--- Script completed ---"
echo "Debug log saved to: $LOG_FILE"
echo "CSV inventory saved to: $CSV_FILE"

# Show CSV summary
if [ -f "$CSV_FILE" ]; then
    total_rows=$(wc -l < "$CSV_FILE")
    data_rows=$((total_rows - 1))  # Subtract header row
    echo "CSV contains $data_rows resource entries"
    
    # Show CSV structure
    echo ""
    echo "CSV file structure preview:"
    echo "=========================="
    head -n 3 "$CSV_FILE" | while IFS= read -r line; do
        echo "$line"
    done
    if [ $data_rows -gt 2 ]; then
        echo "... (and $((data_rows - 2)) more data rows)"
    fi
fi

# Restore original stdout/stderr
exec 1>&3 2>&4
exec 3>&- 4>&-

echo "Debug log saved to: $LOG_FILE"
echo "CSV inventory saved to: $CSV_FILE"