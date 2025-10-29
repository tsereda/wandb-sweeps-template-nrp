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
    SWEEP_ID=$(echo "$FULL_AGENT_CMD" | sed 's/.*\///') # Extract just the sweep ID
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
echo ""
echo "--- Checking for existing jobs for '$SWEEP_NAME' ---"
EXISTING_JOB_NAMES=$(kubectl get jobs -o name 2>/dev/null | grep "sweep-${SWEEP_NAME}-" | sed 's:^job.batch/::')
STARTING_SWEEP_NUMBER=1

if [ -n "$EXISTING_JOB_NAMES" ]; then
    BOLD=$'\033[1m'
    NORMAL=$'\033[0m'
    
    JOB_COUNT=$(echo "$EXISTING_JOB_NAMES" | grep -c .)
    JOB_WORD=$([ "$JOB_COUNT" -eq 1 ] && echo "job" || echo "jobs")

    # List all found jobs and their pods
    
    echo "Found $JOB_COUNT existing $JOB_WORD:"
    # Indent the list of jobs for clarity
    echo "$EXISTING_JOB_NAMES" | sed 's/^/  /'

    JOB_LIST_CSV=$(echo "$EXISTING_JOB_NAMES" | tr '\n' ',' | sed 's/,$//')
    
    echo ""
    echo "Associated pods:"
    # Get all pods, sort by creation time
    POD_LIST=$(kubectl get pods --selector="job-name in ($JOB_LIST_CSV)" --no-headers 2>/dev/null)
    
    if [ -n "$POD_LIST" ]; then
        echo "$POD_LIST" | sed 's/^/  /'
        
        # We still need the oldest pod info for the second confirmation
        OLDEST_POD_LINE=$(echo "$POD_LIST" | head -1)
        OLDEST_POD_NAME=$(echo "$OLDEST_POD_LINE" | awk '{print $1}')
        OLDEST_POD_AGE=$(echo "$OLDEST_POD_LINE" | awk '{print $NF}')
    else
        echo "  No running or completed pods found for these jobs."
        OLDEST_POD_NAME="<unknown>"
        OLDEST_POD_AGE="<unknown>"
    fi
    echo "" # Add a blank line before the prompt


    # --- MODIFIED BLOCK: Exit if user cancels deletion ---
    # Two-step confirmation
    read -p "Delete all $JOB_COUNT listed $JOB_WORD? (y/n): " confirm1
    
    case "$confirm1" in
        [yY]|[yY][eE][sS])
            # The oldest pod info is still used here as a final safety check
            read -p "${BOLD}ARE YOU SURE? (Oldest pod: '$OLDEST_POD_NAME', Age: $OLDEST_POD_AGE) (y/n): ${NORMAL}" confirm2
            case "$confirm2" in
                [yY]|[yY][eE][sS])
                    echo "Deleting $JOB_COUNT $JOB_WORD..."
                    echo "$EXISTING_JOB_NAMES" | xargs kubectl delete job
                    echo "✓ Jobs deleted. Starting new agents from 1."
                    STARTING_SWEEP_NUMBER=1
                    ;;
                *)
                    # --- CHANGE: Exit on 'no' ---
                    echo "Deletion cancelled. Exiting."
                    exit 0
                    # --- END CHANGE ---
                    ;;
            esac
            ;;
        *)
            # --- CHANGE: Exit on 'no' ---
            echo "Keeping existing jobs. Exiting."
            exit 0
            # --- END CHANGE ---
            ;;
    esac
    # --- END MODIFIED BLOCK ---
    
else
    echo "No existing jobs found. Starting from 1."
    STARTING_SWEEP_NUMBER=1
fi


# --- 4. Loop and Deploy Agents ---
echo ""
echo "=== Starting Agent Deployment ($NUM_AGENTS agent(s)) ==="

LAST_JOB_NAME=""
LAST_CONFIG_FILE=""

for i in $(seq 0 $((NUM_AGENTS - 1)))
do
    SWEEP_NUMBER=$((STARTING_SWEEP_NUMBER + i))
    CURRENT_AGENT_NUM=$((i + 1))
    JOB_NAME="sweep-${SWEEP_NAME}-${SWEEP_NUMBER}"
    CONFIG_FILE="agent-${SWEEP_NAME}-${SWEEP_NUMBER}.yml"
    
    echo "--- Deploying Agent $CURRENT_AGENT_NUM/$NUM_AGENTS (Job: $JOB_NAME) ---"
    
    LAST_JOB_NAME=$JOB_NAME
    LAST_CONFIG_FILE=$CONFIG_FILE

    # 1. Generate agent config file
    sed -e "s/{SWEEP_NAME}/$SWEEP_NAME/g" \
        -e "s/{SWEEP_NUMBER}/$SWEEP_NUMBER/g" \
        -e "s/{SWEEP_ID}/$SWEEP_ID/g" \
        template.yml > "$CONFIG_FILE"
    echo "   Generated config: $CONFIG_FILE"

    # 2. Apply kubernetes configuration
    kubectl apply -f "$CONFIG_FILE"
    echo "   Applied config to kubernetes."

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