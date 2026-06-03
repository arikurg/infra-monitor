#!/usr/bin/env python3
"""
smoke_test.py - post-deploy smoke test for the infra-learning 3-tier app.

Runs in the GitHub Actions `deploy` job (the self-hosted runner that has kubectl
and the kind cluster) right after `make k8s-deploy`. It verifies that every tier
actually rolled out AND is serving traffic, then exits non-zero if anything is
wrong - so a broken deploy fails the pipeline loudly instead of sitting there
looking green.

Checks performed:
  1. Workload readiness - the app/web Deployments and the db StatefulSet report
     their rollout complete (queried through kubectl, i.e. the Kubernetes API).
  2. app health         - GET /health and /api/status on svc/app:3000, reached
                          through a short-lived `kubectl port-forward`.
  3. web health         - GET /health on the NodePort the kind cluster maps to
                          localhost:8080.
  4. db health          - `pg_isready` run inside the db-0 pod.

No third-party dependencies: standard library only, plus the `kubectl` binary
that's already on the runner.

Config via environment variables (defaults match this repo):
  NAMESPACE       infra-learning
  APP_DEPLOY      app
  WEB_DEPLOY      web
  DB_STATEFULSET  db
  APP_SVC         app
  APP_PORT        3000
  WEB_URL         http://localhost:8080
  KUBECTL         kubectl
  HTTP_TIMEOUT    5     (seconds per HTTP request)
  ROLLOUT_TIMEOUT 60    (seconds to wait for each rollout)
"""

import json
import os
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

# ---- config -----------------------------------------------------------------
NS        = os.environ.get("NAMESPACE", "infra-learning")
APP_DEPLOY = os.environ.get("APP_DEPLOY", "app")
WEB_DEPLOY = os.environ.get("WEB_DEPLOY", "web")
DB_STS     = os.environ.get("DB_STATEFULSET", "db")
APP_SVC    = os.environ.get("APP_SVC", "app")
APP_PORT   = int(os.environ.get("APP_PORT", "3000"))
WEB_URL    = os.environ.get("WEB_URL", "http://localhost:8080").rstrip("/")
KUBECTL    = os.environ.get("KUBECTL", "kubectl")
HTTP_TIMEOUT    = int(os.environ.get("HTTP_TIMEOUT", "5"))
ROLLOUT_TIMEOUT = int(os.environ.get("ROLLOUT_TIMEOUT", "60"))

LOCAL_FWD_PORT = 33000  # local port for the app port-forward

# ---- tiny output helpers ----------------------------------------------------
results = []  # list of (name, ok, detail)


def record(name, ok, detail=""):
    results.append((name, ok, detail))
    mark = "PASS" if ok else "FAIL"
    line = f"[{mark}] {name}"
    if detail:
        line += f" - {detail}"
    print(line, flush=True)


def kubectl(*args, check=False, capture=True):
    """Run a kubectl command, always scoped to the target namespace."""
    cmd = [KUBECTL, "-n", NS, *args]
    return subprocess.run(
        cmd,
        check=check,
        text=True,
        capture_output=capture,
    )


# ---- check 1: workloads rolled out -----------------------------------------
def check_rollout(kind, name):
    """`kubectl rollout status` returns 0 only when the workload is fully ready.
    This respects whatever replica count the HPA has currently set for `app`."""
    proc = subprocess.run(
        [KUBECTL, "-n", NS, "rollout", "status", f"{kind}/{name}",
         f"--timeout={ROLLOUT_TIMEOUT}s"],
        text=True, capture_output=True,
    )
    ok = proc.returncode == 0
    detail = (proc.stdout or proc.stderr).strip().splitlines()[-1] if (proc.stdout or proc.stderr) else ""
    record(f"rollout {kind}/{name}", ok, detail)
    return ok


# ---- check 2/3: HTTP health -------------------------------------------------
def http_get(url):
    """Return (status_code, body_text). Raises on connection failure."""
    req = urllib.request.Request(url, method="GET")
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
        return resp.getcode(), resp.read().decode("utf-8", "replace")


def check_http(name, url, expect_json_overall=False):
    try:
        code, body = http_get(url)
    except urllib.error.HTTPError as e:
        record(name, False, f"HTTP {e.code} from {url}")
        return False
    except Exception as e:
        record(name, False, f"{type(e).__name__}: {e} ({url})")
        return False

    if code != 200:
        record(name, False, f"HTTP {code} from {url}")
        return False

    if expect_json_overall:
        # /api/status returns {"overall": "...", "services": [...]} in this app.
        # If that shape is present, require overall to be healthy.
        try:
            data = json.loads(body)
            overall = data.get("overall")
            if overall is not None and str(overall).lower() != "healthy":
                record(name, False, f"overall='{overall}' at {url}")
                return False
        except json.JSONDecodeError:
            pass  # not JSON - a 200 is good enough for a smoke test

    record(name, True, f"HTTP 200 from {url}")
    return True


# ---- app needs a port-forward (it's an internal ClusterIP service) ----------
def wait_for_port(port, timeout=10):
    deadline = time.time() + timeout
    while time.time() < deadline:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(0.5)
            if s.connect_ex(("127.0.0.1", port)) == 0:
                return True
        time.sleep(0.3)
    return False


def check_app_via_port_forward():
    pf = subprocess.Popen(
        [KUBECTL, "-n", NS, "port-forward", f"svc/{APP_SVC}",
         f"{LOCAL_FWD_PORT}:{APP_PORT}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        if not wait_for_port(LOCAL_FWD_PORT):
            record("app port-forward", False, "forward never became reachable")
            return
        record("app port-forward", True, f"svc/{APP_SVC} -> localhost:{LOCAL_FWD_PORT}")
        base = f"http://localhost:{LOCAL_FWD_PORT}"
        check_http("app /health", f"{base}/health")
        check_http("app /api/status", f"{base}/api/status", expect_json_overall=True)
    finally:
        pf.terminate()
        try:
            pf.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pf.kill()


# ---- check 4: database ------------------------------------------------------
def check_db():
    # StatefulSet pods are named <sts>-0, <sts>-1, ...; we check the first.
    pod = f"{DB_STS}-0"
    proc = kubectl("exec", pod, "--", "pg_isready", "-q")
    ok = proc.returncode == 0
    detail = "pg_isready: accepting connections" if ok else \
             (proc.stderr or proc.stdout or "pg_isready failed").strip()
    record(f"db {pod} pg_isready", ok, detail)


# ---- main -------------------------------------------------------------------
def main():
    print(f"== smoke test :: namespace '{NS}' ==", flush=True)

    check_rollout("deployment", APP_DEPLOY)
    check_rollout("deployment", WEB_DEPLOY)
    check_rollout("statefulset", DB_STS)

    check_app_via_port_forward()
    check_http("web /health", f"{WEB_URL}/health")
    check_db()

    failed = [name for name, ok, _ in results if not ok]
    print("\n== summary ==", flush=True)
    print(f"{len(results) - len(failed)}/{len(results)} checks passed", flush=True)
    if failed:
        print("FAILED: " + ", ".join(failed), flush=True)
        sys.exit(1)
    print("All smoke checks passed.", flush=True)


if __name__ == "__main__":
    main()
