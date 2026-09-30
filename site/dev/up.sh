#!/usr/bin/env bash
# Dev loop: throwaway Grimmory (from the Kindle plugin harness, seeded with
# 5 sample books, user tester / harness-pass-123) + the site on :8430.
#   dev/up.sh        start both
#   dev/up.sh down   stop both and wipe the throwaway data
set -euo pipefail
cd "$(dirname "$0")/.."
H=$(cd ../kindle-plugin/harness && pwd)
DC="docker compose -f $H/compose.yml"
API=http://localhost:16060

if [[ "${1:-}" == "down" ]]; then
  pkill -f "uvicorn app.main:app" 2>/dev/null || true
  (cd $H && ./run.sh down) >/dev/null 2>&1 || true
  echo "stopped"; exit 0
fi

if ! curl -sf $API/api/v1/healthcheck >/dev/null; then
  echo "== starting throwaway Grimmory"
  rm -rf $H/work && mkdir -p $H/work/books
  python3 $H/make_epubs.py $H/work/books >/dev/null
  (cd $H && $DC up -d db grimmory >/dev/null)
  for i in $(seq 1 90); do curl -sf $API/api/v1/healthcheck >/dev/null && break; sleep 2; done
  curl -sf -X POST $API/api/v1/setup -H 'Content-Type: application/json' \
    -d '{"username":"tester","email":"tester@example.test","name":"Tester","password":"harness-pass-123"}' >/dev/null
  TOKEN=$(curl -sf -X POST $API/api/v1/auth/login -H 'Content-Type: application/json' \
    -d '{"username":"tester","password":"harness-pass-123"}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["accessToken"])')
  curl -sf -X POST $API/api/v1/libraries -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d '{"name":"Test","icon":"book","iconType":"LUCIDE","paths":[{"path":"/books"}],"watch":false}' >/dev/null
  for i in $(seq 1 60); do
    n=$(curl -sf $API/api/v1/books -H "Authorization: Bearer $TOKEN" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' || echo 0)
    [[ "$n" == "5" ]] && break; sleep 2
  done
  echo "   library has $n books"
fi

pkill -f "uvicorn app.main:app" 2>/dev/null || true
export GRIMMORY_URL=$API GRIMMORY_PUBLIC_URL=$API SESSION_SECRET=dev-only-secret-not-for-production SECURE_COOKIES=false
nohup .venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8430 --reload > dev/site.log 2>&1 &
for i in $(seq 1 30); do curl -sf http://127.0.0.1:8430/healthz >/dev/null && break; sleep 1; done
echo "== site: http://127.0.0.1:8430  (login tester / harness-pass-123)  log: site/dev/site.log"
