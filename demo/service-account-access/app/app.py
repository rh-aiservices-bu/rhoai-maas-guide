#!/usr/bin/env python3
"""
model-client - a tiny in-cluster app that calls a MaaS-governed model using its
own ServiceAccount token.

The point of this app is what it does NOT contain: no API key, no client secret,
no credential of any kind. It reads the token Kubernetes projects into the pod at

    /var/run/secrets/kubernetes.io/serviceaccount/token

and sends it as the bearer token. MaaS validates it with TokenReview, resolves
the ServiceAccount's subscription, and applies that subscription's rate limit.

The token is re-read on every call because kubelet rotates it in place.

Environment:
    MAAS_URL        base URL, e.g. https://maas.apps.<domain>
    MODEL_PATH      KServe resource name, used in the URL path
    MODEL_SERVED    served model name, used in the request body
    PORT            listen port (default 8080)
"""
import json
import os
import ssl
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
NS_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/namespace"

MAAS_URL = os.environ.get("MAAS_URL", "").rstrip("/")
MODEL_PATH = os.environ.get("MODEL_PATH", "facebook-opt-125m-simulated")
MODEL_SERVED = os.environ.get("MODEL_SERVED", "facebook/opt-125m")
PORT = int(os.environ.get("PORT", "8080"))

# The cluster's ingress certificate is not in this image's trust store. A real
# deployment would mount the CA bundle; for a demo we skip verification.
SSL_CTX = ssl.create_default_context()
SSL_CTX.check_hostname = False
SSL_CTX.verify_mode = ssl.CERT_NONE


def sa_token():
    """Re-read on every call - kubelet rotates this file in place."""
    with open(TOKEN_PATH) as f:
        return f.read().strip()


def identity():
    """Decode the projected token to show who this pod is. Display only."""
    import base64
    try:
        p = sa_token().split(".")[1]
        p += "=" * (-len(p) % 4)
        return json.loads(base64.urlsafe_b64decode(p)).get("sub", "unknown")
    except Exception:
        return "unknown"


def call_model(prompt, max_tokens=32, retries=1):
    """Call the model as this pod's ServiceAccount.

    Retries once on 5xx: maas-api returns 500 on the first request after an idle
    period, while it reopens its database connection. Not worth surfacing.
    """
    body = json.dumps({
        "model": MODEL_SERVED,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
    }).encode()

    last = (0, {"error": "no attempt made"})
    for attempt in range(retries + 1):
        req = urllib.request.Request(
            f"{MAAS_URL}/llm/{MODEL_PATH}/v1/chat/completions",
            data=body, method="POST",
            headers={"Content-Type": "application/json",
                     # The whole trick: the projected ServiceAccount token,
                     # re-read each call because kubelet rotates it.
                     "Authorization": f"Bearer {sa_token()}"},
        )
        try:
            with urllib.request.urlopen(req, context=SSL_CTX, timeout=30) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            raw = e.read().decode(errors="replace")
            try:
                parsed = json.loads(raw)
            except Exception:
                parsed = {"error": raw[:200]}
            last = (e.code, parsed)
            if e.code < 500 or attempt == retries:
                return last
        except Exception as e:
            last = (0, {"error": str(e)})
            if attempt == retries:
                return last
    return last


PAGE = """<!doctype html>
<meta charset="utf-8"><title>model-client</title>
<style>
 body{font:15px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
      background:#f6f7f9;color:#1a1d21;margin:0}
 .w{max-width:760px;margin:0 auto;padding:32px 20px}
 h1{font-size:20px;margin:0 0 4px}
 .sub{color:#6a7280;font-size:13px;margin:0 0 22px}
 .card{background:#fff;border:1px solid #e2e5ea;border-radius:10px;padding:18px 20px;margin:0 0 16px}
 .kv{display:grid;grid-template-columns:130px 1fr;gap:6px 14px;font-size:13px}
 .kv div:nth-child(odd){color:#6a7280}
 code{font-family:ui-monospace,Menlo,monospace;font-size:12.5px}
 pre{background:#0f1115;color:#e6e6e6;padding:12px 14px;border-radius:8px;overflow-x:auto;margin:10px 0 0}
 input{width:100%;padding:9px 11px;border:1px solid #e2e5ea;border-radius:6px;font-size:14px}
 .row{display:flex;gap:8px;margin-top:10px}
 button{background:#c9342b;color:#fff;border:0;border-radius:6px;padding:9px 16px;font-size:14px;cursor:pointer}
 button.ghost{background:#fff;color:#1a1d21;border:1px solid #e2e5ea}
 .bar{display:flex;height:10px;border-radius:5px;overflow:hidden;margin:12px 0 6px}
 .bar i{display:block}.ok{background:#2e7d32}.lim{background:#b26a00}
</style>
<div class="w">
  <h1>model-client</h1>
  <p class="sub">An in-cluster app calling a MaaS model with its ServiceAccount token.
     It holds no API key and no secret.</p>

  <div class="card">
    <div class="kv">
      <div>running as</div><div><code id="id">…</code></div>
      <div>token source</div><div><code>/var/run/secrets/kubernetes.io/serviceaccount/token</code></div>
      <div>MaaS</div><div><code id="maas">…</code></div>
      <div>model</div><div><code id="model">…</code></div>
    </div>
  </div>

  <div class="card">
    <input id="p" value="say hello in three words" onkeydown="if(event.key==='Enter')ask()">
    <div class="row">
      <button onclick="ask()">Ask the model</button>
      <button class="ghost" onclick="burst()">Burst 20 requests</button>
    </div>
    <div id="out"></div>
  </div>
</div>
<script>
const $=i=>document.getElementById(i);
fetch('/api/whoami').then(r=>r.json()).then(d=>{
  $('id').textContent=d.identity; $('maas').textContent=d.maas_url;
  $('model').textContent=d.model_served+'  (path: '+d.model_path+')';});
async function ask(){
  $('out').innerHTML='<p style="color:#6a7280">calling…</p>';
  const r=await (await fetch('/api/ask',{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({prompt:$('p').value})})).json();
  $('out').innerHTML = r.status===200
    ? '<pre>'+r.content+'</pre><p style="color:#6a7280;font-size:13px">usage: '+JSON.stringify(r.usage)+'</p>'
    : '<pre>HTTP '+r.status+'\\n'+JSON.stringify(r.body,null,1)+'</pre>';
}
async function burst(){
  $('out').innerHTML='<p style="color:#6a7280">sending 20 requests…</p>';
  const r=await (await fetch('/api/burst',{method:'POST'})).json();
  const t=(r.ok+r.limited+r.other)||1;
  $('out').innerHTML='<div class="bar"><i class="ok" style="width:'+(r.ok/t*100)+'%"></i>'+
    '<i class="lim" style="width:'+(r.limited/t*100)+'%"></i></div>'+
    '<p style="color:#6a7280;font-size:13px"><b>'+r.ok+'</b> ok · <b>'+r.limited+
    '</b> rate-limited (429) · '+r.other+' other · '+r.tokens+' tokens</p>';
}
</script>
"""


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json"):
        raw = body if isinstance(body, bytes) else body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, fmt, *a):
        print(fmt % a, flush=True)          # so `oc logs` shows the calls

    def do_GET(self):
        if self.path == "/":
            return self._send(200, PAGE, "text/html; charset=utf-8")
        if self.path == "/healthz":
            return self._send(200, json.dumps({"ok": True}))
        if self.path == "/api/whoami":
            return self._send(200, json.dumps({
                "identity": identity(), "maas_url": MAAS_URL,
                "model_served": MODEL_SERVED, "model_path": MODEL_PATH}))
        self._send(404, json.dumps({"error": "not found"}))

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        payload = json.loads(self.rfile.read(n) or b"{}") if n else {}

        if self.path == "/api/ask":
            status, resp = call_model(payload.get("prompt", "hello"))
            if status == 200:
                print(f"model call ok: {resp.get('usage')}", flush=True)
                return self._send(200, json.dumps({
                    "status": 200,
                    "content": resp["choices"][0]["message"]["content"],
                    "usage": resp.get("usage")}))
            print(f"model call failed: HTTP {status} {str(resp)[:120]}", flush=True)
            return self._send(200, json.dumps({"status": status, "body": resp}))

        if self.path == "/api/burst":
            ok = lim = other = tokens = 0
            for _ in range(20):
                status, resp = call_model("hi", max_tokens=4)
                if status == 200:
                    ok += 1
                    tokens += (resp.get("usage") or {}).get("total_tokens", 0)
                elif status == 429:
                    lim += 1
                else:
                    other += 1
            print(f"burst: {ok} ok / {lim} rate-limited / {other} other", flush=True)
            return self._send(200, json.dumps(
                {"ok": ok, "limited": lim, "other": other, "tokens": tokens}))

        self._send(404, json.dumps({"error": "not found"}))


if __name__ == "__main__":
    print(f"model-client starting as {identity()}", flush=True)
    print(f"  MaaS:  {MAAS_URL}", flush=True)
    print(f"  model: {MODEL_SERVED} (path {MODEL_PATH})", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
