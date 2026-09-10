#!/usr/bin/env bash
#
# test-inference.sh - Quick smoke test for MaaS inference
#
# Usage:
#   ./scripts/test-inference.sh --base-url <url> --api-key <key>
#   ./scripts/test-inference.sh --base-url https://maas.apps.cluster.example.com --api-key <key>
#   ./scripts/test-inference.sh --base-url <url> --api-key <key> --model publishers/llm/models/facebook/opt-125m --prompt "What is AI?"
#

set -euo pipefail

MODEL="publishers/llm/models/facebook/opt-125m"
PROMPT="Hello, how are you?"
MAX_TOKENS=50
ENDPOINT="chat/completions"
API_KEY=""
BASE_URL=""

usage() {
    sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//'
    echo ""
    echo "Options:"
    echo "  --base-url URL      (required) MaaS gateway URL (e.g. https://maas.apps.cluster.example.com)"
    echo "  --api-key KEY       (required) MaaS API key"
    echo "  --model MODEL       MaaS model ID (default: $MODEL)"
    echo "  --prompt TEXT       Prompt text (default: \"$PROMPT\")"
    echo "  --max-tokens N      Max tokens to generate (default: $MAX_TOKENS)"
    echo "  --endpoint TYPE     completions | chat/completions (default: $ENDPOINT)"
    echo "  --list-models       List available models and exit"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base-url)     BASE_URL="$2"; shift 2 ;;
        --api-key)      API_KEY="$2"; shift 2 ;;
        --model)        MODEL="$2"; shift 2 ;;
        --prompt)       PROMPT="$2"; shift 2 ;;
        --max-tokens)   MAX_TOKENS="$2"; shift 2 ;;
        --endpoint)     ENDPOINT="$2"; shift 2 ;;
        --list-models)  LIST_MODELS=true; shift ;;
        -h|--help)      usage ;;
        *)              echo "Unknown option: $1"; usage ;;
    esac
done

BASE_URL="${BASE_URL%/}"

if [[ -z "$BASE_URL" ]]; then
    echo "ERROR: --base-url is required" >&2
    echo "Usage: $0 --base-url <url> --api-key <key>" >&2
    exit 1
fi

if [[ "${LIST_MODELS:-}" == "true" ]]; then
    if [[ -z "$API_KEY" ]]; then
        echo "ERROR: --api-key is required" >&2
        exit 1
    fi
    echo "Available models at ${BASE_URL}/v1/models:"
    curl -sk "${BASE_URL}/v1/models" \
        -H "Authorization: Bearer ${API_KEY}" | python3 -m json.tool
    exit 0
fi

if [[ -z "$API_KEY" ]]; then
    echo "ERROR: --api-key is required" >&2
    echo "Usage: $0 --base-url <url> --api-key <key>" >&2
    exit 1
fi

if [[ "$ENDPOINT" == "chat/completions" ]]; then
    BODY=$(python3 -c "
import json, sys
print(json.dumps({
    'model': sys.argv[1],
    'messages': [{'role': 'user', 'content': sys.argv[2]}],
    'max_tokens': int(sys.argv[3])
}))" "$MODEL" "$PROMPT" "$MAX_TOKENS")
else
    BODY=$(python3 -c "
import json, sys
print(json.dumps({
    'model': sys.argv[1],
    'prompt': sys.argv[2],
    'max_tokens': int(sys.argv[3])
}))" "$MODEL" "$PROMPT" "$MAX_TOKENS")
fi

URL="${BASE_URL}/v1/${ENDPOINT}"

echo "Model:    $MODEL"
echo "Endpoint: $URL"
echo "Prompt:   $PROMPT"
echo ""

RESPONSE=$(curl -sk --max-time 30 -w '\n%{http_code}' \
    "${URL}" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$BODY" 2>&1)

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY_OUT=$(echo "$RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]; then
    echo "$BODY_OUT" | python3 -m json.tool
else
    echo "ERROR: HTTP $HTTP_CODE" >&2
    echo "$BODY_OUT" >&2
    exit 1
fi
