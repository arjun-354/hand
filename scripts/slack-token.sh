#!/usr/bin/env bash
# Stores your Slack user token (xoxp-...) in the macOS Keychain for Hand, then checks it.
# The token is typed at a hidden prompt: it never appears on screen, in a file, or in shell history.
set -euo pipefail
APP="$(cd "$(dirname "$0")/.." && pwd)/build/Hand.app"
echo "Paste your Slack User OAuth Token (starts with xoxp-) at the prompt below. It stays hidden."
# -w with no value makes `security` prompt for it; -T lets Hand read it without asking every time.
security add-generic-password -U -s com.arjun.hand -a slack-user-token -T "$APP" -w
TOKEN="$(security find-generic-password -s com.arjun.hand -a slack-user-token -w)"
curl -sS https://slack.com/api/auth.test -H "Authorization: Bearer $TOKEN" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("Connected to Slack as", d["user"], "in", d["team"]) if d.get("ok") else print("Slack says:", d.get("error"))'
