#!/usr/bin/env bash
# Checks the Gemini key in ~/.config/hand/.env and lists the Flash models it can use. Never prints the key.
set -euo pipefail
KEY="${GEMINI_API_KEY:-$(sed -n 's/^GEMINI_API_KEY=//p' ~/.config/hand/.env 2>/dev/null | tr -d "\"' ")}"
[[ -z "$KEY" ]] && { echo "No key found. Put GEMINI_API_KEY=... in ~/.config/hand/.env"; exit 1; }
curl -sS "https://generativelanguage.googleapis.com/v1beta/models?pageSize=200" -H "x-goog-api-key: $KEY" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["error"]["message"] if "error" in d else "\n".join(m["name"] for m in d["models"] if "flash" in m["name"]))'
