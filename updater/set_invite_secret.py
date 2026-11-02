"""Creates the invite-code signing secret (once), keeps a backup in
%APPDATA%\\MessiahUpdater\\owner.json, and stores it as the GitHub Actions
secret MESSIAH_INVITE_SECRET so the IPA build can use it. The secret is
never printed or committed."""
import json
import os
import secrets
import subprocess
import sys

path = os.path.join(os.environ["APPDATA"], "MessiahUpdater", "owner.json")
os.makedirs(os.path.dirname(path), exist_ok=True)
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except (OSError, ValueError):
    data = {}

if not data.get("inviteSecret"):
    data["inviteSecret"] = secrets.token_hex(32)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
    print("Created a new invite secret (backed up in owner.json).")
else:
    print("Using the invite secret already in owner.json.")

repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
result = subprocess.run(["gh", "secret", "set", "MESSIAH_INVITE_SECRET"], input=data["inviteSecret"],
                        text=True, cwd=repo)
if result.returncode != 0:
    sys.exit("Could not store the secret on GitHub (is gh logged in?).")
print("Stored as GitHub secret MESSIAH_INVITE_SECRET.")
