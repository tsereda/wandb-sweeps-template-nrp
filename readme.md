1. get wandb key from wandb.ai
2. kubectl create secret generic NAME_OF_SECRET --from-literal=key=YOUR_WANDB_KEY
3. chmod +x sweep.sh
4. ./sweep.sh
5. python sweepyml.py SWEEP_ID