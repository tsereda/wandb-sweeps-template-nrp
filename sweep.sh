#!/bin/bash
#
# launch-sweep.sh
#
# Creates a new wandb sweep and launches one or more agents
# as Kubernetes jobs.
#
# Usage:
#   ./launch-sweep.sh       # Creates a new sweep, launches 1 agent
#   ./launch-sweep.sh 5     # Creates a new sweep, launches 5 agents
#

# --- Defaults ---
NUM_AGENTS=1
SWEEP_FILE="sweep.yml"

# --- Parse positional argument for number of agents ---
if [ $# -eq 1 ]; then
    if ! [[ "$1" =~ ^[0-9]+$ ]] || [ "$1" -eq 0 ]; then
        echo "Error: Argument must be a positive integer for the number of agents."
        echo "Usage: $0 [NUM_AGENTS]"
        exit 1
    fi
    NUM_AGENTS=$1
    echo "Will launch $NUM_AGENTS agent(s)."
elif [ $# -gt 1 ]; then
    echo "Error: Too many arguments."
    echo "Usage: $0 [NUM_AGENTS]"
    exit 1
fi


echo "Using sweep file: $SWEEP_FILE"

# --- 1. Extract and Clean Sweep Name ---
SWEEP_NAME=$(grep "^name:" "$SWEEP_FILE" 2>/dev/null | cut -d':' -f2 | sed 's/^ *//;s/ *#.*//')

if [ -z "$SWEEP_NAME" ]; then
    echo "Warning: No 'name' field found in $SWEEP_FILE, using default name 'sweep'"
    SWEEP_NAME="sweep"
else
    # Clean the sweep name for kubernetes naming
    SWEEP_NAME=$(echo "$SWEEP_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g')
    echo "Cleaned sweep name: $SWEEP_NAME"
fi


# --- 2. Create New Sweep ID ---
echo ""
echo "Creating new wandb sweep from $SWEEP_FILE..."

# Capture both stdout and stderr
SWEEP_OUTPUT=$(wandb sweep "$SWEEP_FILE" 2>&1)

echo "Wandb output:"
echo "$SWEEP_OUTPUT"

# Extract sweep ID
SWEEP_ID=""
FULL_AGENT_CMD=""

# Method 1: Look for the full wandb agent command
FULL_AGENT_CMD=$(echo "$SWEEP_OUTPUT" | grep -oE 'wandb agent [^/]+/[^/]+/[a-zA-Z0-9]+' | head -1)

if [ -n "$FULL_AGENT_CMD" ]; then
    # Extract just the sweep ID from the full command
    SWEEP_ID=$(echo "$FULL_AGENT_CMD" | sed 's/.*\///')
else
    # Method 2: Look for URL pattern
    SWEEP_ID=$(echo "$SWEEP_OUTPUT" | grep -oE 'https://wandb\.ai/[^/]+/[^/]+/sweeps/([a-zA-Z0-9]+)' | sed 's/.*sweeps\///' | head -1)
    
    # Method 3: Look for any 8+ character alphanumeric string (potential sweep ID)
    if [ -z "$SWEEP_ID" ]; then
        SWEEP_ID=$(echo "$SWEEP_OUTPUT" | grep -oE '\b[a-zA-Z0-9]{8,}\b' | tail -1)
    fi
fi

if [ -z "$SWEEP_ID" ]; then
    echo "Error: Could not extract sweep ID from wandb output"
    echo "Full output:"
    echo "$SWEEP_OUTPUT"
    exit 1
fi
echo "✓ Extracted new sweep ID: $SWEEP_ID"


# --- 3. Check for Existing Jobs ---
# --- MODIFIED: This section now checks for pods and their age ---
echo ""
echo "--- Checking for existing jobs for '$SWEEP_NAME' ---"
EXISTING_JOB_NAMES=$(kubectl get jobs -o name 2>/dev/null | grep "sweep-${SWEEP_NAME}-" | sed 's:^job.batch/::')

STARTING_SWEEP_NUMBER=1 # Default

if [ -n "$EXISTING_JOB_NAMES" ]; then
    # Define ANSI color codes for bolding
    BOLD=$'\033[1m'
    NORMAL=$'\033[0m'
    
    echo "   Found existing jobs and their associated pods:"
    
    # Loop through each job name found
    echo "$EXISTING_JOB_NAMES" | while read -r job_name; do
        echo "     Job: $job_name"
        
        # Get all pods for this job using the job-name selector
        # The default 'kubectl get pods' output includes a human-readable AGE column at the end
        POD_LIST_OUTPUT=$(kubectl get pods --selector="job-name=$job_name" --no-headers 2>/dev/null)
        
        if [ -n "$POD_LIST_OUTPUT" ]; then
            # If pods were found, loop through each line of output
            echo "$POD_LIST_OUTPUT" | while read -r pod_line; do
                # Use awk to parse the line:
                # $1 = POD NAME
                # $3 = STATUS
                # $NF = LAST COLUMN (AGE)
                POD_NAME=$(echo "$pod_line" | awk '{print $1}')
                POD_STATUS=$(echo "$pod_line" | awk '{print $3}')
                POD_AGE=$(echo "$pod_line" | awk '{print $NF}')
                
                # Print the bolded pod info
                echo "       ${BOLD}- Pod: $POD_NAME (Status: $POD_STATUS, Age: $POD_AGE)${NORMAL}"
            done
        else
            echo "       (No running or completed pods found for this job)"
        fi
    done
    
    echo "" # Add a newline for spacing
    
    # Ask for confirmation, now with bolding
    read -p "   ${BOLD}Are you sure you want to delete all listed jobs and their pods? (y/n): ${NORMAL} " user_response
    
    case "$user_response" in
        [yY]|[yY][eE][sS])
            # User said YES
            echo "   Deleting jobs..."
            # Pipe names to xargs to handle multiple jobs safely
            echo "$EXISTING_JOB_NAMES" | xargs kubectl delete job
            echo "   ✓ Jobs deleted. Starting new agents from number 1."
            STARTING_SWEEP_NUMBER=1
            ;;
        *)
            # User said NO (or anything else)
            echo "   Keeping existing jobs."
            # Find last number and increment
            LAST_NUMBER=$(echo "$EXISTING_JOB_NAMES" | sed "s/.*sweep-${SWEEP_NAME}-//" | sort -n | tail -1)
            STARTING_SWEEP_NUMBER=$((LAST_NUMBER + 1))
            echo "   New agents will start from number $STARTING_SWEEP_NUMBER."
            ;;
    esac
else
    echo "   No existing jobs found. Starting from number 1."
    STARTING_SWEEP_NUMBER=1
fi


# --- 4. Loop and Deploy Agents ---
echo ""
echo "=== Starting Agent Deployment ($NUM_AGENTS agent(s)) ==="

# Store the name of the last created job/config for the summary
LAST_JOB_NAME=""
LAST_CONFIG_FILE=""

for i in $(seq 0 $((NUM_AGENTS - 1)))
do
    SWEEP_NUMBER=$((STARTING_SWEEP_NUMBER + i))
    CURRENT_AGENT_NUM=$((i + 1))

    echo ""
    echo "--- Deploying Agent $CURRENT_AGENT_NUM of $NUM_AGENTS (Job Number: $SWEEP_NUMBER) ---"
    
    # Step B: Generate agent config file
    JOB_NAME="sweep-${SWEEP_NAME}-${SWEEP_NUMBER}"
    CONFIG_FILE="agent-${SWEEP_NAME}-${SWEEP_NUMBER}.yml"
    
    # Store for final summary
    LAST_JOB_NAME=$JOB_NAME
    LAST_CONFIG_FILE=$CONFIG_FILE

    echo "1. Generating agent config:"
    echo "   Job name: $JOB_NAME"
    echo "   Config file: $CONFIG_FILE"

    # Replace {SWEEP_NAME}, {SWEEP_NUMBER}, and {SWEEP_ID} in template
    sed -e "s/{SWEEP_NAME}/$SWEEP_NAME/g" \
        -e "s/{SWEEP_NUMBER}/$SWEEP_NUMBER/g" \
        -e "s/{SWEEP_ID}/$SWEEP_ID/g" \
        template.yml > "$CONFIG_FILE"

    echo "   ✓ Created: $CONFIG_FILE"

    # Step C: Apply kubernetes configuration
    echo "2. Applying kubernetes configuration..."
    kubectl apply -f "$CONFIG_FILE"
    echo "   ✓ Applied $CONFIG_FILE to kubernetes"

done


# --- 5. Final Summary ---
echo ""
echo "=== Deployment Complete ==="
echo "Launched $NUM_AGENTS agent(s) for sweep:"
echo "  Sweep Name: $SWEEP_NAME"
echo "  Sweep ID: $SWEEP_ID"
echo ""
echo "The last agent created was:"
echo "  Job Name: $LAST_JOB_NAME"
echo "  Config File: $LAST_CONFIG_FILE"
echo ""

if [ -n "$FULL_AGENT_CMD" ]; then
    echo "To monitor the sweep, run:"
    echo "$FULL_AGENT_CMD"
else
    echo "To monitor the sweep, run:"
    echo "wandb agent <username>/<project>/$SWEEP_ID"
    echo "(Replace <username>/<project> with your wandb username and project name)"
fi