#!/bin/bash
# Smoke test for the tradingagents-api image — run by
# .github/workflows/tradingagents-deploy.yml's smoke-test job against the
# CI stack (docker-compose.ci.yml) it just started.
#
# Deliberately does NOT exercise POST /run (a real analysis) — that needs
# real Anthropic/FinnHub keys and costs real money per call. This only
# proves the container boots, uvicorn serves, and the two read-only
# endpoints respond — enough to catch "image doesn't start" or "route
# broke" without spending API budget on every push.
set -euo pipefail

BASE_URL="http://localhost:8000"
MAX_WAIT=30

echo "==> Waiting for API to become healthy (up to ${MAX_WAIT}s)…"
for i in $(seq 1 "$MAX_WAIT"); do
  if curl -sf "${BASE_URL}/health" > /dev/null 2>&1; then
    echo "    up after ${i}s"
    break
  fi
  if [ "$i" -eq "$MAX_WAIT" ]; then
    echo "FAIL: API never became healthy within ${MAX_WAIT}s"
    exit 1
  fi
  sleep 1
done

echo "==> GET /health"
HEALTH=$(curl -sf "${BASE_URL}/health")
echo "    $HEALTH"
echo "$HEALTH" | grep -q '"ok":true' || { echo "FAIL: /health did not report ok"; exit 1; }

echo "==> GET /reports (should respond with a JSON array, even if empty)"
REPORTS=$(curl -sf "${BASE_URL}/reports")
echo "    $REPORTS" | head -c 200
echo "$REPORTS" | grep -qE '^\[' || { echo "FAIL: /reports did not return a JSON array"; exit 1; }

echo "==> GET / (viewer HTML — proves FastAPI's static route replaced nginx correctly)"
curl -sf "${BASE_URL}/" | grep -qi "<html" || { echo "FAIL: / did not return HTML"; exit 1; }

echo "==> Smoke test passed"
