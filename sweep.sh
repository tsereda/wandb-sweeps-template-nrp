#!/bin/bash

SWEEP_FILE="sweep.yml"

echo "Using sweep file: $SWEEP_FILE"

# Extract sweep name from sweep.yml
SWEEP_NAME=$(grep "^name:" "$SWEEP_FILE" | cut -d':' -f2 | sed 's/^ *//;s/ *#.*//')

if [ -z "$SWEEP_NAME" ]; then
    echo "Warning: No 'name' field found in $SWEEP_FILE, using default name 'sweep'"
    SWEEP_NAME="sweep"
else
    # Clean the sweep name for kubernetes naming (lowercase, no spaces, etc.)
    SWEEP_NAME=$(echo "$SWEEP_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g')
    echo "Extracted sweep name: $SWEEP_NAME"
fi

# Find the next available number by checking existing jobs
echo ""
echo "Finding next available job number..."
EXISTING_JOBS=$(kubectl get jobs -o name 2>/dev/null | grep "wandb-sweep-${SWEEP_NAME}-" | sed "s/.*${SWEEP_NAME}-//" | sort -n)
if [ -z "$EXISTING_JOBS" ]; then
    SWEEP_NUMBER=1
else
    LAST_NUMBER=$(echo "$EXISTING_JOBS" | tail -1)
    SWEEP_NUMBER=$((LAST_NUMBER + 1))
fi

echo "Using sweep number: $SWEEP_NUMBER"

# Handle command line argument for manual sweep ID
if [ $# -eq 1 ]; then
    SWEEP_ID="$1"
    echo "Using provided sweep ID: $SWEEP_ID"
else
    # Step 1: Create wandb sweep
    echo ""
    echo "1. Creating wandb sweep from $SWEEP_FILE..."
    
    # Capture both stdout and stderr
    SWEEP_OUTPUT=$(wandb sweep "$SWEEP_FILE" 2>&1)
    
    echo "Wandb output:"
    echo "$SWEEP_OUTPUT"
    
    # Extract sweep ID using multiple methods
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
        echo ""
        echo "Please manually run 'wandb sweep $SWEEP_FILE' and note the sweep ID"
        echo "Then run this script with the sweep ID as an argument:"
        echo "$0 <sweep_id>"
        exit 1
    fi
fi

echo "✓ Extracted sweep ID: $SWEEP_ID"

# Step 2: Generate agent config file
JOB_NAME="wandb-sweep-${SWEEP_NAME}-${SWEEP_NUMBER}"
CONFIG_FILE="agent-${SWEEP_NAME}-${SWEEP_NUMBER}.yml"

echo ""
echo "2. Generating agent config:"
echo "   Job name: $JOB_NAME"
echo "   Config file: $CONFIG_FILE"
echo "   Sweep ID: $SWEEP_ID"

# Replace {SWEEP_NAME}, {SWEEP_NUMBER}, and {SWEEP_ID} in template
sed -e "s/{SWEEP_NAME}/$SWEEP_NAME/g" -e "s/{SWEEP_NUMBER}/$SWEEP_NUMBER/g" -e "s/{SWEEP_ID}/$SWEEP_ID/g" template.yml > "$CONFIG_FILE"

echo "✓ Created: $CONFIG_FILE"

# Step 3: Apply kubernetes configuration
echo ""
echo "3. Applying kubernetes configuration..."

kubectl apply -f "$CONFIG_FILE"

echo "✓ Applied $CONFIG_FILE to kubernetes"

echo ""
echo "=== Deployment Complete ==="
echo "Job name: $JOB_NAME"
echo "Sweep Name: $SWEEP_NAME"
echo "Sweep Number: $SWEEP_NUMBER"
echo "Sweep ID: $SWEEP_ID"
echo "Agent config: $CONFIG_FILE"
echo "Kubernetes deployment applied successfully!"
echo ""
if [ -n "$FULL_AGENT_CMD" ]; then
    echo "To monitor the sweep, run:"
    echo "$FULL_AGENT_CMD"
else
    echo "To monitor the sweep, run:"
    echo "wandb agent <username>/<project>/$SWEEP_ID"
    echo "(Replace <username>/<project> with your wandb username and project name)"
fi