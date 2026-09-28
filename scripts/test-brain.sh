#!/usr/bin/env bash
# Checks the Brain's key (Groq by default; BRAIN_PROVIDER=meta for Meta). Never prints the key.
set -euo pipefail
val() { sed -n "s/^$1=//p" ~/.config/hand/.env 2>/dev/null | tr -d "\"' "; }
if [[ "$(val BRAIN_PROVIDER)" == "meta" ]]; then
  KEY="$(val META_API_KEY)"; BASE=https://api.meta.ai/v1; MODEL=muse-spark-1.3; EXTRA='"reasoning_effort":"low"'
else
  KEY="$(val GROQ_API_KEY)"; BASE=https://api.groq.com/openai/v1; MODEL=openai/gpt-oss-120b; EXTRA='"reasoning_effort":"low","include_reasoning":false'
fi
[[ -z "$KEY" ]] && { echo "No key found in ~/.config/hand/.env (GROQ_API_KEY=...)"; exit 1; }
echo "Provider: $BASE"
curl -sS "$BASE/models" -H "Authorization: Bearer $KEY" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("error") or "Models: " + ", ".join(sorted(m["id"] for m in d.get("data",[]))))'
curl -sS -w "\n%{time_total}" "$BASE/chat/completions" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d "{\"model\":\"$MODEL\",$EXTRA,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with just: ok\"}]}" \
  | python3 -c 'import json,sys; raw=sys.stdin.read(); body,_,t=raw.rpartition("\n"); d=json.loads(body); print("Test ('"$MODEL"'):", d["choices"][0]["message"]["content"] if "choices" in d else d.get("error",d), "in", t+"s")'
