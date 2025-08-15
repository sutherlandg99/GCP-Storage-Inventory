#!/usr/bin/env bash

# --- GCP Multi-Project IAM Audit Script ---
# This script iterates through all GCP projects the user has access to and reports
# on the project details and IAM users/permissions.

# Requirements:
# 1. `gcloud` CLI installed and authenticated (`gcloud auth login`).
# 2. `jq` command-line JSON processor. Install with `sudo apt-get install jq` or `brew install jq`.
# 3. Sufficient IAM permissions (e.g., Project Viewer, IAM Viewer) on the projects to be audited.

# --- Configuration ---
TIMESTAMP=$(date +%s)
LOG_FILE="gcp_iam_audit_${TIMESTAMP}.txt"
CSV_FILE="gcp_iam_inventory_${TIMESTAMP}.csv"

# Create temporary directory for processing
TEMP_DIR="/tmp/gcp_iam_audit_$$"
mkdir -p "$TEMP_DIR"

# Cleanup function
cleanup() {
    echo "🧹 Cleaning up temporary files..."
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# --- Setup Logging ---
exec 3>&1 4>&2
exec > >(tee -a "$LOG_FILE") 2>&1

echo "Starting GCP Multi-Project IAM Audit"
echo "=================================================================="
echo "Timestamp: $(date)"
echo "=================================================================="

# Initialize CSV file with headers
echo "Project_Name,Project_ID,Project_Number,Project_Link,User_Email,User_Type,Roles" > "$CSV_FILE"
echo "✅ CSV inventory file initialized: $CSV_FILE"

# Check if required tools are available
command -v gcloud >/dev/null 2>&1 || { echo "❌ Error: gcloud CLI not found"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "❌ Error: jq not found"; exit 1; }

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
    local project_name="$1"
    local project_id="$2"
    local project_number="$3"
    local project_link="$4"
    local user_email="$5"
    local user_type="$6"
    local roles="$7"
    
    # Escape all fields
    project_name=$(escape_csv_field "$project_name")
    project_id=$(escape_csv_field "$project_id")
    project_number=$(escape_csv_field "$project_number")
    project_link=$(escape_csv_field "$project_link")
    user_email=$(escape_csv_field "$user_email")
    user_type=$(escape_csv_field "$user_type")
    roles=$(escape_csv_field "$roles")
    
    # Append to CSV
    echo "$project_name,$project_id,$project_number,$project_link,$user_email,$user_type,$roles" >> "$CSV_FILE"
}

# Function to process IAM bindings for a project
process_project_iam() {
    local project_id="$1"
    local project_name="$2"
    local project_number="$3"
    local project_link="$4"
    
    echo "Fetching IAM policy..."
    
    # Get IAM policy for the project
    local iam_policy_file="$TEMP_DIR/iam_policy_${project_id}.json"
    gcloud projects get-iam-policy "$project_id" --format=json > "$iam_policy_file" 2>/dev/null
    
    if [ ! -s "$iam_policy_file" ]; then
        echo "  ⚠️  Could not fetch IAM policy for project: $project_id"
        add_csv_row "$project_name" "$project_id" "$project_number" "$project_link" "ERROR" "ERROR" "Could not fetch IAM policy"
        return 1
    fi
    
    # Create a temporary file to store member-role mappings
    local members_file="$TEMP_DIR/members_${project_id}.txt"
    local aggregated_file="$TEMP_DIR/aggregated_${project_id}.txt"
    
    # Extract all bindings and create member-role mappings
    jq -r '.bindings[] | 
        .role as $role | 
        .members[] | 
        . + "|" + $role' "$iam_policy_file" 2>/dev/null | sort > "$members_file"
    
    if [ ! -s "$members_file" ]; then
        echo "No IAM members found in project: $project_id"
        add_csv_row "$project_name" "$project_id" "$project_number" "$project_link" "NO_MEMBERS" "N/A" "No IAM members configured"
        return 0
    fi
    
    # Aggregate roles for each member using awk instead of associative arrays
    awk -F'|' '
    {
        member = $1
        role = $2
        # Clean up the role name (remove "roles/" prefix)
        gsub(/^roles\//, "", role)
        
        if (members[member] == "") {
            members[member] = role
        } else {
            members[member] = members[member] "; " role
        }
    }
    END {
        for (member in members) {
            print member "|" members[member]
        }
    }' "$members_file" | sort > "$aggregated_file"
    
    # Count total unique members
    local total_members=$(wc -l < "$aggregated_file" 2>/dev/null || echo "0")
    echo "Found $total_members unique IAM members"
    
    # Process each unique member with their aggregated roles
    local member_count=0
    while IFS='|' read -r member roles; do
        if [ -z "$member" ]; then
            continue
        fi
        
        ((member_count++))
        
        # Determine member type
        local member_type="unknown"
        local member_email="$member"
        
        # Clean up member string - remove any special characters that might cause issues
        member=$(echo "$member" | sed 's/\?.*$//')  # Remove anything after ? (for deleted accounts)
        
        if [[ "$member" == "user:"* ]]; then
            member_type="User"
            member_email="${member#user:}"
        elif [[ "$member" == "serviceAccount:"* ]]; then
            member_type="Service Account"
            member_email="${member#serviceAccount:}"
        elif [[ "$member" == "group:"* ]]; then
            member_type="Group"
            member_email="${member#group:}"
        elif [[ "$member" == "domain:"* ]]; then
            member_type="Domain"
            member_email="${member#domain:}"
        elif [[ "$member" == "deleted:user:"* ]]; then
            member_type="Deleted User"
            member_email="${member#deleted:user:}"
        elif [[ "$member" == "deleted:serviceAccount:"* ]]; then
            member_type="Deleted Service Account"
            member_email="${member#deleted:serviceAccount:}"
        elif [[ "$member" == "deleted:group:"* ]]; then
            member_type="Deleted Group"
            member_email="${member#deleted:group:}"
        elif [[ "$member" == "projectOwner:"* ]]; then
            member_type="Project Owner"
            member_email="${member#projectOwner:}"
        elif [[ "$member" == "projectEditor:"* ]]; then
            member_type="Project Editor"
            member_email="${member#projectEditor:}"
        elif [[ "$member" == "projectViewer:"* ]]; then
            member_type="Project Viewer"
            member_email="${member#projectViewer:}"
        elif [[ "$member" == "allUsers" ]]; then
            member_type="Public"
            member_email="allUsers"
        elif [[ "$member" == "allAuthenticatedUsers" ]]; then
            member_type="All Authenticated"
            member_email="allAuthenticatedUsers"
        fi
        
        # Clean up email - remove UID suffixes for deleted accounts
        member_email=$(echo "$member_email" | sed 's/\?.*$//')
        
        # Add to CSV
        add_csv_row "$project_name" "$project_id" "$project_number" "$project_link" "$member_email" "$member_type" "$roles"
        
        # Show progress for large member lists
        if [ $((member_count % 10)) -eq 0 ]; then
            echo "    Processed $member_count/$total_members members..."
        fi
    done < "$aggregated_file"
    
    echo "  ✅ Completed IAM audit for project: $project_id"
    
    # Cleanup temp files
    rm -f "$iam_policy_file" "$members_file" "$aggregated_file"
}

# Enable cloudresourcemanager API to get project list
echo "🔧 Enabling Cloud Resource Manager API..."
gcloud services enable cloudresourcemanager.googleapis.com --quiet 2>/dev/null

echo "Fetching all accessible projects..."
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
    echo "Available projects:"
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
read -p "Press Enter to continue with the IAM audit..."

# Display header
echo ""
echo "================================================================================================"
printf "%-40s %-15s %s\n" "PROJECT ID" "STATUS" "MEMBERS"
echo "================================================================================================"

# Statistics
TOTAL_PROJECTS_PROCESSED=0
TOTAL_UNIQUE_USERS=0
PROJECTS_WITH_ERRORS=0

# Process each selected project
echo "$SELECTED_PROJECTS" | while read -r project_id; do
    if [ -z "$project_id" ]; then
        continue
    fi
    
    ((TOTAL_PROJECTS_PROCESSED++))
    
    echo ""
    echo "Processing project: $project_id"
    echo "=================================================================="
    
    # Get detailed project information
    echo "Fetching project details..."
    project_info=$(gcloud projects describe "$project_id" --format=json 2>/dev/null)
    
    if [ -z "$project_info" ] || [ "$project_info" = "null" ]; then
        echo "  ❌ Error: Could not fetch project details for: $project_id"
        ((PROJECTS_WITH_ERRORS++))
        printf "%-40s %-15s %s\n" "$project_id" "ERROR" "Could not fetch details"
        continue
    fi
    
    # Extract project details
    project_name=$(echo "$project_info" | jq -r '.name // "N/A"')
    project_number=$(echo "$project_info" | jq -r '.projectNumber // "N/A"')
    project_state=$(echo "$project_info" | jq -r '.lifecycleState // "ACTIVE"')
    project_create_time=$(echo "$project_info" | jq -r '.createTime // "N/A"')
    
    # Generate GCP Console link
    project_link="https://console.cloud.google.com/home/dashboard?project=${project_id}"
    
    echo "Project Details:"
    echo "     Name: $project_name"
    echo "     Number: $project_number"
    echo "     State: $project_state"
    echo "     Created: $project_create_time"
    echo "     Console: $project_link"
    
    # Process IAM bindings
    process_project_iam "$project_id" "$project_name" "$project_number" "$project_link"
    
    # Count unique members for this project
    project_member_count=$(grep -c "^.*,${project_id}," "$CSV_FILE" 2>/dev/null || echo "0")
    
    # Display summary for this project
    printf "%-40s %-15s %s\n" "$project_id" "COMPLETED" "$project_member_count members"
    
done

echo "================================================================================================"
echo ""

# Calculate final statistics
TOTAL_CSV_LINES=$(wc -l < "$CSV_FILE" 2>/dev/null || echo "0")
TOTAL_IAM_ENTRIES=$((TOTAL_CSV_LINES - 1))  # Subtract header

# Count unique users across all projects
UNIQUE_USERS=$(tail -n +2 "$CSV_FILE" 2>/dev/null | cut -d',' -f5 | sort -u | wc -l || echo "0")

# Count by member type
echo "IAM MEMBER STATISTICS"
echo "================================================================================================"
echo "Member Type Distribution:"
tail -n +2 "$CSV_FILE" 2>/dev/null | cut -d',' -f6 | sort | uniq -c | sort -rn | while read count type; do
    printf "  %-20s: %s\n" "$type" "$count"
done
echo ""

# Show top users by number of projects they have access to
echo "TOP 10 USERS BY PROJECT ACCESS"
echo "================================================================================================"
tail -n +2 "$CSV_FILE" 2>/dev/null | cut -d',' -f2,5 | sort -u | cut -d',' -f2 | sort | uniq -c | sort -rn | head -10 | while read count email; do
    # Clean up email if it has quotes
    email=$(echo "$email" | sed 's/"//g')
    printf "  %-50s: %s projects\n" "$email" "$count"
done
echo "================================================================================================"
echo ""

# Show projects with most permissive access
echo "⚠️  PROJECTS WITH PUBLIC OR WIDE ACCESS"
echo "================================================================================================"
if grep -q "allUsers\|allAuthenticatedUsers" "$CSV_FILE" 2>/dev/null; then
    grep "allUsers\|allAuthenticatedUsers" "$CSV_FILE" 2>/dev/null | while IFS=',' read -r proj_name proj_id rest; do
        # Clean up fields
        proj_name=$(echo "$proj_name" | sed 's/"//g')
        proj_id=$(echo "$proj_id" | sed 's/"//g')
        echo "  ⚠️  $proj_id ($proj_name) has public or wide access configured"
    done
else
    echo "  ✅ No projects found with public access (allUsers or allAuthenticatedUsers)"
fi
echo "================================================================================================"
echo ""

# Performance metrics
AUDIT_END_TIME=$(date +%s)
AUDIT_DURATION=$((AUDIT_END_TIME - TIMESTAMP))
AUDIT_DURATION_MIN=$(printf "%.1f" "$(echo "scale=1; $AUDIT_DURATION / 60" | bc -l 2>/dev/null || echo "0.0")")

echo "FINAL SUMMARY"
echo "================================================================================================"
echo "Projects Processed: $(echo "$SELECTED_PROJECTS" | wc -l)"
echo "Total IAM Entries: $TOTAL_IAM_ENTRIES"
echo "Unique Users/Members: $UNIQUE_USERS"
echo "Projects with Errors: $PROJECTS_WITH_ERRORS"
echo "================================================================================================"
echo ""

echo "PERFORMANCE METRICS"
echo "================================================================================================"
printf "Audit Duration: %s seconds (%s minutes)\n" "${AUDIT_DURATION}" "${AUDIT_DURATION_MIN}"
echo "Average Time per Project: $(echo "scale=1; $AUDIT_DURATION / $(echo "$SELECTED_PROJECTS" | wc -l)" | bc -l 2>/dev/null || echo "0") seconds"
echo ""

echo "OUTPUT FILES"
echo "================================================================================================"
echo "Detailed Log: $LOG_FILE"
echo "CSV Inventory: $CSV_FILE"
echo ""

# CSV file statistics
if [ -f "$CSV_FILE" ]; then
    CSV_SIZE=$(du -h "$CSV_FILE" 2>/dev/null | cut -f1 || echo "unknown")
    echo "CSV Statistics:"
    echo "  - Total rows: $TOTAL_IAM_ENTRIES (excluding header)"
    echo "  - File size: $CSV_SIZE"
    echo "  - Columns: Project_Name, Project_ID, Project_Number, Project_Link, User_Email, User_Type, Roles"
    echo ""
fi

echo ""
echo "✅ GCP Multi-Project IAM Audit Complete!"
echo "================================================================================================"

# Restore stdout/stderr
exec 1>&3 2>&4
exec 3>&- 4>&-