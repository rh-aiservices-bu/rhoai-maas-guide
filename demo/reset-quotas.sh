#!/usr/bin/env bash
# Reset the token quotas consumed by the demos.
#
# Rate limit counters are held in memory by Limitador, so restarting it returns
# every subscription to a full allowance. Useful between rehearsals of the
# hour-windowed demos, where waiting for the window to roll is impractical.
#
# This is cluster-wide: it clears the counters for EVERY subscription, not just
# one demo's. On a demo cluster that is what you want. Do not run it on a shared
# or production cluster, where it would hand every tenant a fresh allowance.
#
# Usage:  ./reset-quotas.sh
set -uo pipefail

oc whoami >/dev/null 2>&1 || { echo "not logged in to a cluster"; exit 1; }

NS=kuadrant-system

# A Limitador backed by Redis keeps counters outside the pod, where a restart
# will not clear them. Check before promising a reset.
STORAGE=$(oc get limitador -n "$NS" -o jsonpath='{.items[0].spec.storage}' 2>/dev/null)
if [ -n "$STORAGE" ] && [ "$STORAGE" != "null" ]; then
  echo "Limitador is using external storage, so a restart will not clear the counters:"
  echo "  ${STORAGE}"
  echo "Wait for the rate limit window to roll instead."
  exit 1
fi

echo "==> Restarting Limitador (counters are in memory)"
oc delete pod -n "$NS" -l app=limitador || { echo "no limitador pod found in ${NS}"; exit 1; }
oc wait --for=condition=Ready pod -n "$NS" -l app=limitador --timeout=180s || {
  echo "Limitador did not become Ready - check: oc get pods -n ${NS}"; exit 1; }

# The gateway needs a moment to reconnect before limits are enforced again.
sleep 10

echo
echo "Quotas reset. Every subscription starts from a full allowance."
echo "Rate limiting is enforced again as soon as Limitador is Ready - this"
echo "clears the counters, it does not disable the limits."
