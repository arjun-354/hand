#!/usr/bin/env bash
# Checks the TypeSafe key in ~/.config/hand/.env with one tiny request. Never prints the key.
set -euo pipefail
KEY="${TYPESAFE_API_KEY:-$(sed -n 's/^TYPESAFE_API_KEY=//p' ~/.config/hand/.env 2>/dev/null | tr -d "\"' ")}"
[[ -z "$KEY" ]] && { echo "No key found. Put TYPESAFE_API_KEY=... in ~/.config/hand/.env"; exit 1; }
curl -sS https://api.typesafe.ai/v1/systemone \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"state":{"spoken_request":"open spot a fie"},"model":"jev-latest","questions":{"app":{"type":"choice","instructions":"Which application is the user referring to? The text is speech-to-text and may be misheard.","criteria":{"Spotify":null,"Safari":null,"Slack":null,"Notes":null}}}}'
echo
