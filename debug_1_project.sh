#!/usr/bin/env bash

# --- GCP Storage Debugging Script (v10 - Debug Fix) ---
# This script tests GCS and Filestore with proper error handling and fixes

# --- Configuration ---
PROJECT_ID_GCS="sdo-ml"
PROJECT_ID_FS="hl-compute"
LOG_FILE="gcp_debug_log_final_$(date +%s).txt"

# --- Setup Logging ---
exec 3>&1 4>&2
exec > >(tee -a "$LOG_FILE") 2>&1
# Note: set -x is disabled for clean progress display

echo "--- Starting Final Debug Script ---"

# Check if required tools are available
command -v gcloud >/dev/null 2>&1 || { echo "Error: gcloud CLI not found"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq not found"; exit 1; }
command -v bc >/dev/null 2>&1 || { echo "Error: bc not found"; exit 1; }

# --- Part 1: Debug GCS for 'sdo-ml' with corrected flag ---
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

echo -e "\n--- Step 1.2: Calculating total size with live progress ---"
PROJECT_GCS_BYTES=0

# Fix: Use a temporary file to accumulate the total since pipe creates subshell
TEMP_TOTAL=$(mktemp)
echo "0" > "$TEMP_TOTAL"

# Count total buckets for progress tracking
TOTAL_BUCKETS=$(echo "$BUCKET_LIST" | grep -c "gs://")
CURRENT_BUCKET=0

echo "Found $TOTAL_BUCKETS buckets to process..."
echo ""

# Fixed bucket scanning logic - replace the problematic section

echo "$BUCKET_LIST" | while read -r bucket_uri; do
    if [ -n "$bucket_uri" ]; then
        CURRENT_BUCKET=$((CURRENT_BUCKET + 1))
        echo "[$CURRENT_BUCKET/$TOTAL_BUCKETS] Processing bucket: $bucket_uri"
        
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
                printf "\r  Project: %s | Bucket: %s | Elapsed: %s | Status: Scanning...     " \
                    "$project" "$(basename "$bucket")" "$elapsed_display" >&3
                
                sleep 2
                
                # Check if we should stop (parent will kill us)
                if [ ! -f "/tmp/progress_$bucket_safe" ]; then
                    break
                fi
            done
            printf "\r" >&3
        }
        
        # Start the du command - FIXED VERSION
        echo "  Starting size calculation..."
        
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
        
        # Debug output
        echo "DEBUG: Exit code: $du_exit_code" >&3
        echo "DEBUG: Output file size: $(wc -c < "$temp_output")" >&3
        echo "DEBUG: Error file size: $(wc -c < "$temp_error")" >&3
        
        if [ $du_exit_code -eq 0 ]; then
            bucket_size_output=$(cat "$temp_output")
            error_output=$(cat "$temp_error")
            
            echo "DEBUG: Raw stdout for $bucket_uri:" >&3
            echo "$bucket_size_output" >&3
            
            if [ -s "$temp_error" ]; then
                echo "DEBUG: Raw stderr for $bucket_uri:" >&3
                echo "$error_output" >&3
            fi
            
            # IMPROVED PARSING LOGIC
            bucket_bytes=""
            
            # Method 1: Look for the summarize output (should be last line with number)
            if [ -n "$bucket_size_output" ]; then
                # Try different parsing approaches
                
                # Approach 1: Last line starting with digits
                bucket_bytes=$(echo "$bucket_size_output" | grep -E "^[0-9]+" | tail -1 | awk '{print $1}' 2>/dev/null)
                echo "DEBUG: Method 1 result: '$bucket_bytes'" >&3
                
                # Approach 2: If that fails, look for any line with bytes information
                if [[ ! "$bucket_bytes" =~ ^[0-9]+$ ]]; then
                    bucket_bytes=$(echo "$bucket_size_output" | grep -oE '[0-9]+' | tail -1 2>/dev/null)
                    echo "DEBUG: Method 2 result: '$bucket_bytes'" >&3
                fi
                
                # Approach 3: Try parsing total line if present
                if [[ ! "$bucket_bytes" =~ ^[0-9]+$ ]]; then
                    bucket_bytes=$(echo "$bucket_size_output" | grep -i "total" | grep -oE '[0-9]+' | tail -1 2>/dev/null)
                    echo "DEBUG: Method 3 result: '$bucket_bytes'" >&3
                fi
                
                # Approach 4: Parse the summary line differently
                if [[ ! "$bucket_bytes" =~ ^[0-9]+$ ]]; then
                    # Sometimes the output format is different
                    bucket_bytes=$(echo "$bucket_size_output" | awk '/^[0-9]/ {bytes=$1} END {print bytes}' 2>/dev/null)
                    echo "DEBUG: Method 4 result: '$bucket_bytes'" >&3
                fi
            fi
            
            echo "DEBUG: Final parsed bytes: '$bucket_bytes'" >&3
            
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
                echo "DEBUG: Could not parse valid byte count from output" >&3
            fi
        else
            echo "  ✗ Error getting size for $bucket_uri (exit code: $du_exit_code)"
            if [ -s "$temp_error" ]; then
                echo "  Error details: $(cat "$temp_error")"
            fi
            if [ -s "$temp_output" ]; then
                echo "  Output received: $(cat "$temp_output")"
            fi
        fi
        
        # Clean up temp files
        rm -f "$temp_output" "$temp_error"
        echo ""
    fi
done

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

# --- Part 2: Verify Filestore for 'hl-compute' ---
echo -e "\n\n--- VERIFY: Filestore for project: $PROJECT_ID_FS ---"
gcloud config set project "$PROJECT_ID_FS"
gcloud services enable filestore.googleapis.com --project="$PROJECT_ID_FS"
sleep 10

echo "--- Step 2.1: Capturing raw JSON output from gcloud ---"
FS_OUTPUT_RAW=$(gcloud filestore instances list --project="$PROJECT_ID_FS" --format=json 2>&1)
echo "--- Raw output received: ---"
echo "$FS_OUTPUT_RAW" | jq . 2>/dev/null || echo "Could not parse JSON output"

echo -e "\n--- Step 2.2: Processing Filestore instances ---"
if echo "$FS_OUTPUT_RAW" | jq . >/dev/null 2>&1; then
    # Parse Filestore instances and calculate total size (fix case sensitivity)
    FILESTORE_TOTAL_BYTES=$(echo "$FS_OUTPUT_RAW" | jq -r '[.[] | .fileShares[]?.capacityGb // 0] | map(tonumber) | add // 0')
    
    if [ "$FILESTORE_TOTAL_BYTES" != "null" ] && [ "$FILESTORE_TOTAL_BYTES" -gt 0 ]; then
        # Convert GB to bytes for consistency
        FILESTORE_TOTAL_BYTES_ACTUAL=$(echo "$FILESTORE_TOTAL_BYTES * 1024 * 1024 * 1024" | bc)
        FILESTORE_TB=$(echo "scale=2; $FILESTORE_TOTAL_BYTES / 1024" | bc -l)
        
        echo "--- Filestore instances found ---"
        echo "$FS_OUTPUT_RAW" | jq -r '.[] | "Instance: \(.name), Capacity: \(.fileShares[0].capacityGb // 0) GB"'
        echo "--- Total Filestore capacity: $FILESTORE_TOTAL_BYTES GB ($FILESTORE_TB TB) ---"
    else
        echo "--- No Filestore instances found or no capacity data ---"
    fi
else
    echo "--- Error: Could not parse Filestore output as JSON ---"
    echo "Raw output:"
    echo "$FS_OUTPUT_RAW"
fi

echo -e "\n--- Script completed ---"

# Restore original stdout/stderr
exec 1>&3 2>&4
exec 3>&- 4>&-

echo "Debug log saved to: $LOG_FILE"