import wandb

def train():
    wandb.init()
    config = wandb.config
    
    # Your training code here
    for epoch in range(config.epochs):
        loss = 0.5 * (1 - epoch/config.epochs)  # dummy loss
        wandb.log({'loss': loss, 'epoch': epoch})

if __name__ == '__main__':
    train()