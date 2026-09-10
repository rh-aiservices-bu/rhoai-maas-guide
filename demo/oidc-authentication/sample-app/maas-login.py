#!/usr/bin/env python3
"""
maas-login - a minimal sample client for MaaS external OIDC.

Shows what an application does instead of hand-rolling curl:

    1. log the user in against the OIDC issuer
    2. exchange the resulting OIDC token for a MaaS API key
    3. call the model with that API key

Two login modes:

    browser   (default)  authorization code + PKCE - opens a browser, the user
                         logs in to Keycloak, nothing is typed into the terminal.
                         This is what a real client would do.
    password  (--password) direct access grant - no browser, handy for scripted
                         demos and CI. Often disabled by policy in production.

Standard library only - no pip install.

Examples:
    ./maas-login.py login --from-cluster
    ./maas-login.py login --from-cluster --password --username maas-user
    ./maas-login.py whoami
    ./maas-login.py chat "hello there"
"""
import argparse
import base64
import hashlib
import http.server
import json
import os
import secrets
import ssl
import subprocess
import sys
import threading
import urllib.parse
import urllib.request
import webbrowser
from pathlib import Path

CRED_FILE = Path.home() / ".maas" / "credentials.json"

# Demo clusters use self-signed certs. A production client would verify.
SSL_CTX = ssl.create_default_context()
SSL_CTX.check_hostname = False
SSL_CTX.verify_mode = ssl.CERT_NONE


# ---------------------------------------------------------------- helpers ---
def http_post(url, data, headers=None, token=None, retries=1):
    """POST returning parsed JSON.

    Retries once on 5xx: maas-api can return 500 on the first call after an idle
    period (a stale pooled DB connection on the key-validation path). The retry
    succeeds, so it is not worth surfacing to the user.
    """
    body = urllib.parse.urlencode(data).encode() if isinstance(data, dict) else data
    hdrs = dict(headers or {})
    if token:
        hdrs["Authorization"] = f"Bearer {token}"

    last = None
    for attempt in range(retries + 1):
        req = urllib.request.Request(url, data=body, headers=hdrs, method="POST")
        try:
            with urllib.request.urlopen(req, context=SSL_CTX) as r:
                return json.loads(r.read() or b"{}")
        except urllib.error.HTTPError as e:
            last = (e.code, e.read().decode(errors="replace")[:400])
            if e.code < 500 or attempt == retries:
                break
    sys.exit(f"HTTP {last[0]} from {url}\n{last[1]}")


def http_get_json(url):
    req = urllib.request.Request(url)
    with urllib.request.urlopen(req, context=SSL_CTX) as r:
        return json.loads(r.read())


def decode_claims(jwt):
    """Decode a JWT payload. NOTE: decoding is not verifying - no signature check
    happens here. The server validates the signature; this is for display only."""
    payload = jwt.split(".")[1]
    payload += "=" * (-len(payload) % 4)          # restore base64url padding
    return json.loads(base64.urlsafe_b64decode(payload))


def from_cluster():
    """Convenience for demos: read the OIDC config MaaS is actually using.
    A real client would be handed these as configuration, not read the cluster."""
    def oc(*args):
        return subprocess.run(["oc", *args], capture_output=True, text=True).stdout.strip()

    issuer = oc("get", "aitenants.maas.opendatahub.io", "models-as-a-service",
                "-n", "ai-tenants", "-o", "jsonpath={.spec.oidc.issuerUrl}")
    client = oc("get", "aitenants.maas.opendatahub.io", "models-as-a-service",
                "-n", "ai-tenants", "-o", "jsonpath={.spec.oidc.clientId}")
    domain = oc("get", "ingresses.config/cluster", "-o", "jsonpath={.spec.domain}")
    if not issuer:
        sys.exit("Could not read OIDC config from the cluster. Is MaaS configured for OIDC?")
    return issuer, client, f"https://maas.{domain}"


def save(creds):
    CRED_FILE.parent.mkdir(parents=True, exist_ok=True)
    CRED_FILE.write_text(json.dumps(creds, indent=2))
    CRED_FILE.chmod(0o600)


def load():
    if not CRED_FILE.exists():
        sys.exit("Not logged in. Run: ./maas-login.py login --from-cluster")
    return json.loads(CRED_FILE.read_text())


# ------------------------------------------------------------ login flows ---
class _CallbackHandler(http.server.BaseHTTPRequestHandler):
    code = None

    def do_GET(self):
        qs = urllib.parse.urlparse(self.path).query
        _CallbackHandler.code = urllib.parse.parse_qs(qs).get("code", [None])[0]
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        ok = _CallbackHandler.code is not None
        self.wfile.write(
            b"<h2>Signed in - you can close this tab.</h2>" if ok
            else b"<h2>Login failed.</h2>")

    def log_message(self, *a):
        pass                                       # keep the demo output clean


def login_browser(issuer, client_id):
    """Authorization code flow with PKCE. The password is never seen by this app."""
    cfg = http_get_json(f"{issuer}/.well-known/openid-configuration")

    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(
        hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")

    server = http.server.HTTPServer(("127.0.0.1", 0), _CallbackHandler)
    redirect_uri = f"http://localhost:{server.server_port}/callback"

    params = urllib.parse.urlencode({
        "client_id": client_id, "response_type": "code", "scope": "openid groups",
        "redirect_uri": redirect_uri,
        "code_challenge": challenge, "code_challenge_method": "S256",
        "state": secrets.token_urlsafe(16),
    })
    url = f"{cfg['authorization_endpoint']}?{params}"

    print(f"Opening a browser to sign in...\n  {url}\n")
    threading.Thread(target=webbrowser.open, args=(url,), daemon=True).start()
    server.handle_request()                        # blocks until the redirect lands
    if not _CallbackHandler.code:
        sys.exit("No authorization code received.")

    tok = http_post(cfg["token_endpoint"], {
        "grant_type": "authorization_code", "client_id": client_id,
        "code": _CallbackHandler.code, "redirect_uri": redirect_uri,
        "code_verifier": verifier,
    })
    return tok["access_token"]


def login_password(issuer, client_id, username, password):
    """Direct access grant. Simple, but the app handles the user's password."""
    cfg = http_get_json(f"{issuer}/.well-known/openid-configuration")
    tok = http_post(cfg["token_endpoint"], {
        "grant_type": "password", "client_id": client_id,
        "username": username, "password": password, "scope": "openid groups",
    })
    return tok["access_token"]


# --------------------------------------------------------------- commands ---
def cmd_login(a):
    issuer, client_id, maas_url = (a.issuer, a.client_id, a.maas_url)
    if a.from_cluster:
        issuer, client_id, maas_url = from_cluster()
    if not (issuer and client_id and maas_url):
        sys.exit("Need --issuer, --client-id and --maas-url (or --from-cluster).")

    if a.password:
        username = a.username or input("Username: ")
        import getpass
        password = os.environ.get("MAAS_PASSWORD") or getpass.getpass("Password: ")
        oidc_token = login_password(issuer, client_id, username, password)
    else:
        oidc_token = login_browser(issuer, client_id)

    claims = decode_claims(oidc_token)
    print(f"Signed in as {claims.get('preferred_username')}")
    print(f"  groups: {claims.get('groups')}")
    print(f"  issuer: {claims.get('iss')}")

    # The exchange: an OIDC token in, a MaaS API key out.
    resp = http_post(
        f"{maas_url}/maas-api/v1/api-keys",
        json.dumps({"name": a.key_name, "description": "issued by maas-login",
                    "expiresIn": a.ttl}).encode(),
        headers={"Content-Type": "application/json"},
        token=oidc_token,
    )
    if "key" not in resp:
        sys.exit(f"No API key issued: {json.dumps(resp)[:300]}")

    save({"maas_url": maas_url, "api_key": resp["key"],
          "subscription": resp.get("subscription"), "expires_at": resp.get("expiresAt"),
          "username": claims.get("preferred_username"), "groups": claims.get("groups")})
    print(f"\nMaaS API key issued -> subscription '{resp.get('subscription')}'"
          f" (expires {resp.get('expiresAt')})")
    print(f"Saved to {CRED_FILE}")


def cmd_whoami(_):
    c = load()
    print(f"user:         {c.get('username')}")
    print(f"groups:       {c.get('groups')}")
    print(f"subscription: {c.get('subscription')}")
    print(f"expires:      {c.get('expires_at')}")
    print(f"api key:      {c['api_key'][:18]}...")


def cmd_chat(a):
    c = load()
    body = json.dumps({
        "model": a.model,
        "messages": [{"role": "user", "content": a.prompt}],
        "max_tokens": a.max_tokens,
    }).encode()
    resp = http_post(f"{c['maas_url']}/llm/{a.model_path}/v1/chat/completions", body,
                     headers={"Content-Type": "application/json"}, token=c["api_key"])
    print(resp["choices"][0]["message"]["content"])
    if a.verbose:
        print(f"\n[usage: {resp.get('usage')}]")


def main():
    p = argparse.ArgumentParser(description="Sample MaaS OIDC client.")
    sub = p.add_subparsers(dest="cmd", required=True)

    lg = sub.add_parser("login", help="sign in and exchange the OIDC token for a MaaS API key")
    lg.add_argument("--from-cluster", action="store_true",
                    help="read issuer/client/MaaS URL from the cluster via oc (demo convenience)")
    lg.add_argument("--issuer", default=os.environ.get("MAAS_ISSUER"))
    lg.add_argument("--client-id", default=os.environ.get("MAAS_CLIENT_ID", "maas-oidc"))
    lg.add_argument("--maas-url", default=os.environ.get("MAAS_URL"))
    lg.add_argument("--password", action="store_true",
                    help="use the direct access grant instead of a browser login")
    lg.add_argument("--username")
    lg.add_argument("--key-name", default="maas-login")
    lg.add_argument("--ttl", default="8h")
    lg.set_defaults(func=cmd_login)

    wi = sub.add_parser("whoami", help="show the stored identity and subscription")
    wi.set_defaults(func=cmd_whoami)

    ch = sub.add_parser("chat", help="send a prompt using the stored API key")
    ch.add_argument("prompt")
    ch.add_argument("--model", default="facebook/opt-125m", help="served model name")
    ch.add_argument("--model-path", default="facebook-opt-125m-simulated",
                    help="KServe resource name used in the URL path")
    ch.add_argument("--max-tokens", type=int, default=32)
    ch.add_argument("-v", "--verbose", action="store_true")
    ch.set_defaults(func=cmd_chat)

    a = p.parse_args()
    a.func(a)


if __name__ == "__main__":
    main()
