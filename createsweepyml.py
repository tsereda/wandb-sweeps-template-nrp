import sys

if len(sys.argv) != 2:
    print("Usage: python sweepidreplace.py <sweep_id>")
    sys.exit(1)

sweep_id = sys.argv[1]

with open("agent-template.yml", 'r') as f:
    content = f.read()

content = content.replace("{SWEEP_ID}", sweep_id)

with open(f"agent-{sweep_id}.yml", 'w') as f:
    f.write(content)

print(f"Created: agent-{sweep_id}.yml")