#!/usr/bin/env python3
"""
maas-ui - a click-through UI for the MaaS external OIDC demo.

Runs a small local web app that walks the four steps on screen:

    1. Sign in with Keycloak      (authorization code + PKCE, in a browser)
    2. Inspect the token          (the groups claim that drives entitlement)
    3. Exchange it for a MaaS key (which subscription resolved, and why)
    4. Call the model             (single prompt, or a burst to trip the rate limit)

Standard library only - no pip install.

It must listen on localhost: the `maas-oidc` client registers
`http://localhost:*` as its redirect URI. Model calls are proxied through this
app rather than made from the browser, so a self-signed cluster certificate
does not produce a browser warning mid-demo.

Usage:
    ./maas-ui.py --from-cluster          # reads issuer/client/URL via oc
    ./maas-ui.py --from-cluster --port 8080
    MAAS_ISSUER=... MAAS_CLIENT_ID=... MAAS_URL=... ./maas-ui.py
"""
import argparse
import base64
import hashlib
import http.server
import json
import os
import secrets
import socketserver
import ssl
import subprocess
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request
import webbrowser

SSL_CTX = ssl.create_default_context()
SSL_CTX.check_hostname = False
SSL_CTX.verify_mode = ssl.CERT_NONE

CFG = {}          # issuer, client_id, maas_url, oidc discovery document
SESSION = {}      # in-memory: one demo user at a time
PKCE = {}


# ---------------------------------------------------------------- helpers ---
def http_json(url, data=None, headers=None, token=None, retries=1):
    hdrs = dict(headers or {})
    if token:
        hdrs["Authorization"] = f"Bearer {token}"
    body = urllib.parse.urlencode(data).encode() if isinstance(data, dict) else data
    last = None
    for attempt in range(retries + 1):
        req = urllib.request.Request(url, data=body, headers=hdrs,
                                     method="POST" if body is not None else "GET")
        try:
            with urllib.request.urlopen(req, context=SSL_CTX) as r:
                return r.status, json.loads(r.read() or b"{}")
        except urllib.error.HTTPError as e:
            raw = e.read().decode(errors="replace")
            try:
                parsed = json.loads(raw)
            except Exception:
                parsed = {"error": raw[:300]}
            last = (e.code, parsed)
            # maas-api returns 500 on the first call after idle (stale DB conn).
            if e.code < 500 or attempt == retries:
                break
    return last


def decode_claims(jwt):
    """Display only - this performs NO signature verification."""
    p = jwt.split(".")[1]
    p += "=" * (-len(p) % 4)
    return json.loads(base64.urlsafe_b64decode(p))


def from_cluster():
    def oc(*a):
        return subprocess.run(["oc", *a], capture_output=True, text=True).stdout.strip()
    issuer = oc("get", "aitenants.maas.opendatahub.io", "models-as-a-service",
                "-n", "ai-tenants", "-o", "jsonpath={.spec.oidc.issuerUrl}")
    client = oc("get", "aitenants.maas.opendatahub.io", "models-as-a-service",
                "-n", "ai-tenants", "-o", "jsonpath={.spec.oidc.clientId}")
    domain = oc("get", "ingresses.config/cluster", "-o", "jsonpath={.spec.domain}")
    if not issuer:
        sys.exit("Could not read OIDC config from the cluster. Is MaaS configured for OIDC?")
    return issuer, client, f"https://maas.{domain}"


# --------------------------------------------------------------------- UI ---
PAGE = """<!doctype html>
<meta charset="utf-8"><title>MaaS OIDC demo</title>
<style>
 :root{--bg:#f6f7f9;--card:#fff;--ink:#1a1d21;--mut:#6a7280;--line:#e2e5ea;
       --ok:#2e7d32;--warn:#b26a00;--err:#c9342b;--accent:#c9342b}
 *{box-sizing:border-box} body{margin:0;background:var(--bg);color:var(--ink);
   font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
 .wrap{max-width:920px;margin:0 auto;padding:32px 20px 64px}
 h1{font-size:22px;margin:0 0 4px} .sub{color:var(--mut);margin:0 0 24px;font-size:13px}
 .card{background:var(--card);border:1px solid var(--line);border-radius:10px;
   padding:18px 20px;margin:0 0 16px}
 .card.done{border-left:3px solid var(--ok)} .card.idle{opacity:.55}
 .step{font-size:11px;letter-spacing:.08em;text-transform:uppercase;color:var(--mut);margin:0 0 8px}
 h2{font-size:16px;margin:0 0 10px}
 button{background:var(--accent);color:#fff;border:0;border-radius:6px;
   padding:9px 16px;font-size:14px;cursor:pointer}
 button:disabled{background:#c8ccd2;cursor:not-allowed}
 button.ghost{background:#fff;color:var(--ink);border:1px solid var(--line)}
 code,pre{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:13px}
 pre{background:#0f1115;color:#e6e6e6;padding:12px 14px;border-radius:8px;overflow-x:auto;margin:8px 0 0}
 .kv{display:grid;grid-template-columns:150px 1fr;gap:6px 14px;margin:10px 0 0}
 .kv div:nth-child(odd){color:var(--mut);font-size:13px}
 .pill{display:inline-block;background:#eef1f5;border-radius:999px;padding:2px 10px;
   font-size:12px;margin:0 6px 4px 0}
 .pill.hi{background:#e7f3e8;color:var(--ok)}
 input[type=text]{width:100%;padding:9px 11px;border:1px solid var(--line);
   border-radius:6px;font-size:14px}
 .row{display:flex;gap:8px;align-items:center;margin-top:8px}
 .muted{color:var(--mut);font-size:13px}
 .bar{display:flex;height:10px;border-radius:5px;overflow:hidden;margin:10px 0 6px}
 .bar i{display:block} .bar .ok{background:var(--ok)} .bar .lim{background:var(--warn)}
</style>
<div class="wrap">
 <h1>Models-as-a-Service &mdash; external OIDC</h1>
 <p class="sub" id="cfg">loading configuration&hellip;</p>

 <div class="card" id="c1">
  <p class="step">Step 1</p><h2>Sign in with Keycloak</h2>
  <p class="muted">These users exist only in Keycloak &mdash; they have no OpenShift account.
     Sign-in uses the authorization code flow with PKCE, so the password is never seen by this app.</p>
  <div class="row"><button onclick="location='/login'">Sign in with Keycloak</button>
   <span class="muted" id="hint">maas-user / maas-user &nbsp;&middot;&nbsp; restricted-user / restricted-user</span></div>
 </div>

 <div class="card idle" id="c2">
  <p class="step">Step 2</p><h2>The token</h2>
  <div id="tok"><p class="muted">Sign in to see the token claims.</p></div>
 </div>

 <div class="card idle" id="c3">
  <p class="step">Step 3</p><h2>Exchanged for a MaaS API key</h2>
  <div id="key"><p class="muted">The <code>groups</code> claim decides which subscription applies.</p></div>
 </div>

 <div class="card idle" id="c4">
  <p class="step">Step 4</p><h2>Call the model</h2>
  <div class="row"><input type="text" id="p" value="say hello in three words"
        onkeydown="if(event.key==='Enter')send()"><button id="sendb" onclick="send()">Send</button></div>
  <div class="row"><button class="ghost" id="burstb" onclick="burst()">Burst 15 requests</button>
   <span class="muted">shows the rate limit for this subscription</span></div>
  <div id="out"></div>
 </div>
</div>
<script>
const $=id=>document.getElementById(id);
async function refresh(){
  const c=await (await fetch('/api/config')).json();
  $('cfg').innerHTML=`issuer <code>${c.issuer}</code> &nbsp;&middot;&nbsp; client <code>${c.client_id}</code>`;
  const s=await (await fetch('/api/session')).json();
  if(!s.signed_in) return;
  $('c1').className='card done';
  $('c1').querySelector('.row').innerHTML=
    `<span class="muted">Signed in as <b>${s.username}</b></span>
     <button class="ghost" onclick="location='/logout'">Switch user</button>`;
  $('c2').className='card done';
  $('tok').innerHTML=`<div class="kv"><div>preferred_username</div><div><b>${s.username}</b></div>
    <div>groups</div><div>${s.groups.map(g=>`<span class="pill hi">${g}</span>`).join('')}</div>
    <div>issuer</div><div><code>${s.issuer}</code></div>
    <div>expires</div><div>${s.token_exp}</div></div>
    <p class="muted" style="margin-top:10px">Decoded locally for display &mdash; no signature check happens here.
       MaaS verifies the signature against the issuer's public keys.</p>`;
  $('c3').className='card done';
  $('key').innerHTML=`<div class="kv"><div>subscription</div><div><b>${s.subscription}</b></div>
    <div>api key</div><div><code>${s.api_key_masked}</code></div>
    <div>expires</div><div>${s.key_expires}</div></div>`;
  $('c4').className='card done';
}
async function send(){
  $('sendb').disabled=true; $('out').innerHTML='<p class="muted">calling…</p>';
  const r=await (await fetch('/api/chat',{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({prompt:$('p').value})})).json();
  $('sendb').disabled=false;
  $('out').innerHTML = r.ok
    ? `<pre>${r.content}</pre><p class="muted">usage: ${JSON.stringify(r.usage)}</p>`
    : `<pre>HTTP ${r.status}\n${JSON.stringify(r.body,null,1)}</pre>`;
}
async function burst(){
  $('burstb').disabled=true; $('out').innerHTML='<p class="muted">sending 15 requests…</p>';
  const r=await (await fetch('/api/burst',{method:'POST'})).json();
  $('burstb').disabled=false;
  const t=r.ok+r.limited+r.other||1;
  $('out').innerHTML=`<div class="bar">
      <i class="ok" style="width:${r.ok/t*100}%"></i><i class="lim" style="width:${r.limited/t*100}%"></i></div>
    <p class="muted"><b>${r.ok}</b> succeeded &nbsp;·&nbsp; <b>${r.limited}</b> rate-limited (HTTP 429)
       &nbsp;·&nbsp; ${r.other} other &nbsp;·&nbsp; ${r.tokens} tokens consumed</p>`;
}
refresh();
</script>
"""


# ----------------------------------------------------------------- server ---
class Handler(http.server.BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json"):
        raw = body if isinstance(body, bytes) else body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, *a):
        pass

    # ---- GET
    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)

        if path == "/":
            return self._send(200, PAGE, "text/html; charset=utf-8")

        if path == "/api/config":
            return self._send(200, json.dumps(
                {"issuer": CFG["issuer"], "client_id": CFG["client_id"], "maas_url": CFG["maas_url"]}))

        if path == "/api/session":
            if not SESSION:
                return self._send(200, json.dumps({"signed_in": False}))
            return self._send(200, json.dumps({"signed_in": True, **SESSION["public"]}))

        if path == "/logout":
            SESSION.clear()
            self.send_response(302); self.send_header("Location", "/"); self.end_headers()
            return

        if path == "/login":
            verifier = secrets.token_urlsafe(64)
            PKCE["v"] = verifier
            challenge = base64.urlsafe_b64encode(
                hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
            params = urllib.parse.urlencode({
                "client_id": CFG["client_id"], "response_type": "code",
                "scope": "openid groups", "redirect_uri": CFG["redirect_uri"],
                "code_challenge": challenge, "code_challenge_method": "S256",
                "state": secrets.token_urlsafe(12), "prompt": "login",
            })
            self.send_response(302)
            self.send_header("Location", f"{CFG['oidc']['authorization_endpoint']}?{params}")
            self.end_headers()
            return

        if path == "/callback":
            code = qs.get("code", [None])[0]
            if not code:
                return self._send(400, "no authorization code", "text/plain")
            status, tok = http_json(CFG["oidc"]["token_endpoint"], {
                "grant_type": "authorization_code", "client_id": CFG["client_id"],
                "code": code, "redirect_uri": CFG["redirect_uri"], "code_verifier": PKCE.get("v", ""),
            })
            if "access_token" not in tok:
                return self._send(400, f"token exchange failed: {tok}", "text/plain")

            oidc_token = tok["access_token"]
            claims = decode_claims(oidc_token)

            # The exchange this demo is about: OIDC token in, MaaS API key out.
            status, resp = http_json(
                f"{CFG['maas_url']}/maas-api/v1/api-keys",
                json.dumps({"name": "maas-ui", "description": "issued by maas-ui",
                            "expiresIn": "8h"}).encode(),
                headers={"Content-Type": "application/json"}, token=oidc_token)
            if "key" not in resp:
                return self._send(400, f"no API key issued: {resp}", "text/plain")

            import datetime
            SESSION["api_key"] = resp["key"]
            SESSION["public"] = {
                "username": claims.get("preferred_username"),
                "groups": claims.get("groups", []),
                "issuer": claims.get("iss"),
                "token_exp": datetime.datetime.utcfromtimestamp(
                    claims.get("exp", 0)).strftime("%H:%M:%SZ"),
                "subscription": resp.get("subscription"),
                "key_expires": resp.get("expiresAt"),
                "api_key_masked": resp["key"][:18] + "…",
            }
            self.send_response(302); self.send_header("Location", "/"); self.end_headers()
            return

        self._send(404, "not found", "text/plain")

    # ---- POST
    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        if not SESSION:
            return self._send(401, json.dumps({"ok": False, "error": "not signed in"}))
        length = int(self.headers.get("Content-Length") or 0)
        payload = json.loads(self.rfile.read(length) or b"{}") if length else {}

        if path == "/api/chat":
            status, resp = self._infer(payload.get("prompt", "hello"), 32)
            if status == 200:
                return self._send(200, json.dumps({
                    "ok": True, "content": resp["choices"][0]["message"]["content"],
                    "usage": resp.get("usage")}))
            return self._send(200, json.dumps({"ok": False, "status": status, "body": resp}))

        if path == "/api/burst":
            ok = lim = other = tokens = 0
            for _ in range(15):
                status, resp = self._infer("hi", 4)
                if status == 200:
                    ok += 1
                    tokens += (resp.get("usage") or {}).get("total_tokens", 0)
                elif status == 429:
                    lim += 1
                else:
                    other += 1
            return self._send(200, json.dumps(
                {"ok": ok, "limited": lim, "other": other, "tokens": tokens}))

        self._send(404, json.dumps({"error": "not found"}))

    def _infer(self, prompt, max_tokens):
        body = json.dumps({"model": CFG["model_served"],
                           "messages": [{"role": "user", "content": prompt}],
                           "max_tokens": max_tokens}).encode()
        return http_json(f"{CFG['maas_url']}/llm/{CFG['model_path']}/v1/chat/completions",
                         body, headers={"Content-Type": "application/json"},
                         token=SESSION["api_key"])


class ThreadingHTTP(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


def main():
    p = argparse.ArgumentParser(description="Click-through UI for the MaaS OIDC demo.")
    p.add_argument("--from-cluster", action="store_true",
                   help="read issuer/client/MaaS URL from the cluster via oc")
    p.add_argument("--issuer", default=os.environ.get("MAAS_ISSUER"))
    p.add_argument("--client-id", default=os.environ.get("MAAS_CLIENT_ID", "maas-oidc"))
    p.add_argument("--maas-url", default=os.environ.get("MAAS_URL"))
    p.add_argument("--port", type=int, default=8080)
    p.add_argument("--model-served", default="facebook/opt-125m")
    p.add_argument("--model-path", default="facebook-opt-125m-simulated")
    p.add_argument("--no-browser", action="store_true")
    a = p.parse_args()

    issuer, client_id, maas_url = a.issuer, a.client_id, a.maas_url
    if a.from_cluster:
        issuer, client_id, maas_url = from_cluster()
    if not (issuer and client_id and maas_url):
        sys.exit("Need --issuer, --client-id and --maas-url (or --from-cluster).")

    CFG.update(issuer=issuer, client_id=client_id, maas_url=maas_url,
               model_served=a.model_served, model_path=a.model_path,
               redirect_uri=f"http://localhost:{a.port}/callback")
    _, CFG["oidc"] = http_json(f"{issuer}/.well-known/openid-configuration")

    url = f"http://localhost:{a.port}/"
    print(f"MaaS OIDC demo UI\n  issuer: {issuer}\n  MaaS:   {maas_url}\n  open:   {url}\n"
          f"(Ctrl-C to stop)")
    if not a.no_browser:
        threading.Timer(0.6, webbrowser.open, args=(url,)).start()
    try:
        ThreadingHTTP(("127.0.0.1", a.port), Handler).serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")


if __name__ == "__main__":
    main()
