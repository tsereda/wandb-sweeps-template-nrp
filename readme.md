1. get wandb key from wandb.ai
2. create secret wandb in kubernetes (wandb_credentials)
ex. kubectl create secret wandb-credentials ...
3. wandb sweep sweep.yml
4. python createsweepyml.py SWEEP_ID
4. kubectl apply -f agent-#####.yaml