#!/usr/bin/env bash
# One URL for every model - local and external.
#
# Creates an API key for the single-url-demo subscription, lists the models it
# can reach, then calls each of them through the same endpoint. Only the "model"
# field in the request body changes.
#
# Read-only apart from issuing a one-hour API key. Repeatable.
#
# Usage:  ./run-demo.sh
set -uo pipefail

oc whoami >/dev/null 2>&1 || { echo "not logged in to a cluster"; exit 1; }
MAAS="https://maas.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"

KEY=$(curl -sk -m 30 -H "Authorization: Bearer $(oc whoami -t)" -H 'Content-Type: application/json' -X POST \
      -d '{"name":"single-url-demo","description":"single URL demo","expiresIn":"1h","subscription":"single-url-demo"}' \
      "${MAAS}/maas-api/v1/api-keys" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("key",""))' 2>/dev/null)
[ -n "$KEY" ] || { echo "could not create an API key - run ./setup-demo.sh first"; exit 1; }

python3 - "$MAAS" "$KEY" <<'PY'
import json, ssl, sys, time, urllib.error, urllib.request

maas, key = sys.argv[1], sys.argv[2]
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
hdrs = {"Authorization": f"Bearer {key}", "Content-Type": "application/json"}
endpoint = f"{maas}/v1/chat/completions"
prompt = "Hello from the single URL"

def get(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers=hdrs), context=ctx, timeout=30) as r:
        return json.loads(r.read())

def chat(model, retries=1):
    body = json.dumps({"model": model, "messages": [{"role": "user", "content": prompt}], "max_tokens": 12}).encode()
    for attempt in range(retries + 1):
        try:
            req = urllib.request.Request(endpoint, data=body, headers=hdrs, method="POST")
            with urllib.request.urlopen(req, context=ctx, timeout=30) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            if e.code < 500 or attempt == retries:
                return e.code, {"error": e.read().decode(errors="replace")[:120]}
        except Exception as e:
            if attempt == retries:
                return 0, {"error": str(e)[:120]}
        time.sleep(1)

models = get(f"{maas}/maas-api/v1/models")["data"]

print(f"Endpoint   {endpoint}")
print(f"API key    {key[:18]}...   (subscription single-url-demo)\n")

print("Models this key can reach  (GET /maas-api/v1/models)\n")
print(f"  {'id':<50} {'kind':<22} where")
for m in models:
    where = "external provider" if m.get("kind") == "ExternalModel" else "on this cluster"
    print(f"  {m['id']:<50} {m.get('kind',''):<22} {where}")

print(f"\nSame URL, same key - only \"model\" changes\n")
for m in models:
    status, resp = chat(m["id"])
    print(f"  model: {m['id']}")
    if status == 200:
        reply = resp["choices"][0]["message"]["content"].strip()
        print(f"    HTTP 200   served by: {resp.get('model')}")
        print(f"    reply:     {reply[:60]!r}\n")
    else:
        print(f"    HTTP {status}   {resp.get('error','')}\n")

print("The request, for every model:\n")
print(f"  curl {endpoint} \\")
print( "    -H \"Authorization: Bearer $API_KEY\" -H 'Content-Type: application/json' \\")
print( "    -d '{\"model\": \"<id from /v1/models>\", \"messages\": [...]}'")
PY

cat <<'TXT'

One endpoint and one API key reached two models running on this cluster and one
served by an external provider. The model field in the request body chose the
destination. Authentication, subscription checks and token rate limits were
applied the same way to all three.

The external provider replies by echoing the prompt, which is how you can see
that request travelled out to the provider and back.
TXT
