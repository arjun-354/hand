#!/usr/bin/env bash
# Checks the Meta Model API key in ~/.config/hand/.env: lists models and sends one tiny request. Never prints the key.
set -euo pipefail
KEY="${META_API_KEY:-$(sed -n 's/^META_API_KEY=//p' ~/.config/hand/.env 2>/dev/null | tr -d "\"' ")}"
[[ -z "$KEY" ]] && { echo "No key found. Put META_API_KEY=... in ~/.config/hand/.env"; exit 1; }
echo "Models:"
curl -sS https://api.meta.ai/v1/models -H "Authorization: Bearer $KEY" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("error") or "\n".join("  "+m["id"] for m in d.get("data",[])))'
echo "Test request:"
curl -sS -w "\n  (%{time_total}s)\n" https://api.meta.ai/v1/chat/completions -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"model":"muse-spark-1.3","reasoning_effort":"low","messages":[{"role":"user","content":"Reply with just: ok"}]}' \
  | python3 -c 'import json,sys; raw=sys.stdin.read(); body,_,t=raw.rpartition("\n  ("); d=json.loads(body); print("  "+(d["choices"][0]["message"]["content"] if "choices" in d else str(d.get("error",d))), "("+t.strip())'
