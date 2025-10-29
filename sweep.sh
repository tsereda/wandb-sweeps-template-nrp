#!/bin/bash

SWEEP_FILE="sweep.yml"

echo "Using sweep file: $SWEEP_FILE"

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
echo ""
echo "2. Generating agent config with sweep ID: $SWEEP_ID"

# Replace {SWEEP_ID} in template
sed "s/{SWEEP_ID}/$SWEEP_ID/g" template.yml > "agent-$SWEEP_ID.yml"

echo "✓ Created: agent-$SWEEP_ID.yml"

# Step 3: Apply kubernetes configuration
echo ""
echo "3. Applying kubernetes configuration..."

kubectl apply -f "agent-$SWEEP_ID.yml"

echo "✓ Applied agent-$SWEEP_ID.yml to kubernetes"

echo ""
echo "=== Deployment Complete ==="
echo "Sweep ID: $SWEEP_ID"
echo "Agent config: agent-$SWEEP_ID.yml"
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