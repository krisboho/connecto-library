#!/usr/bin/env bash
# End-to-end test of Shelf Sync: throwaway Grimmory + headless KOReader.
#   ./run.sh          run all rounds, leave containers up for inspection
#   ./run.sh down     tear everything down
set -euo pipefail
cd "$(dirname "$0")"
DC="docker compose -f compose.yml"
API=http://localhost:16060
USER=tester
PASS=harness-pass-123
DEV=work/kohome/books/Grimmory

if [[ "${1:-}" == "down" ]]; then $DC --profile test down -v; rm -rf work; exit 0; fi

pass=0; fail=0
check() { if eval "$2"; then echo "  PASS $1"; pass=$((pass+1)); else echo "  FAIL $1"; fail=$((fail+1)); fi; }
jq_py() { python3 -c "import json,sys; d=json.load(sys.stdin); $1"; }

echo "== reset"
$DC --profile test down -v >/dev/null 2>&1 || true
rm -rf work && mkdir -p work/books work/kohome/books/Grimmory work/kohome/koreader/settings
python3 make_epubs.py work/books
echo "this is the user's own file" > "$DEV/Book One.epub"

echo "== start grimmory"
$DC up -d db grimmory >/dev/null
for i in $(seq 1 90); do curl -sf $API/api/v1/healthcheck >/dev/null && break; sleep 2; done
curl -sf $API/api/v1/healthcheck >/dev/null || { echo "grimmory did not start"; exit 1; }

echo "== seed library"
curl -sf -X POST $API/api/v1/setup -H 'Content-Type: application/json' \
  -d "{\"username\":\"$USER\",\"email\":\"tester@example.test\",\"name\":\"Tester\",\"password\":\"$PASS\"}" >/dev/null
TOKEN=$(curl -sf -X POST $API/api/v1/auth/login -H 'Content-Type: application/json' \
  -d "{\"username\":\"$USER\",\"password\":\"$PASS\"}" | jq_py 'print(d["accessToken"])')
AUTH=(-H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json')
curl -sf -X POST $API/api/v1/libraries "${AUTH[@]}" \
  -d '{"name":"Test","icon":"book","iconType":"LUCIDE","paths":[{"path":"/books"}],"watch":false}' >/dev/null
for i in $(seq 1 60); do
  n=$(curl -sf $API/api/v1/books "${AUTH[@]}" | jq_py 'print(len(d))' || echo 0)
  [[ "$n" == "5" ]] && break; sleep 2
done
echo "  library has $n books"
BOOKS_JSON=$(curl -sf $API/api/v1/books "${AUTH[@]}")
bid() { echo "$BOOKS_JSON" | jq_py "print([b['id'] for b in d if b['primaryFile']['fileName'].startswith('$1')][0])"; }
B1=$(bid "Book One"); B2=$(bid "Book Two"); B3=$(bid "Book Three"); B4=$(bid "Book Four"); B5=$(bid "Book Five")
SHELF=$(curl -sf -X POST $API/api/v1/shelves "${AUTH[@]}" -d '{"name":"Kindle","icon":"book","iconType":"LUCIDE"}' | jq_py 'print(d["id"])')
assign()   { curl -sf -X POST $API/api/v1/books/shelves "${AUTH[@]}" -d "{\"bookIds\":[$1],\"shelvesToAssign\":[$SHELF],\"shelvesToUnassign\":[]}" >/dev/null; }
unassign() { curl -sf -X POST $API/api/v1/books/shelves "${AUTH[@]}" -d "{\"bookIds\":[$1],\"shelvesToAssign\":[],\"shelvesToUnassign\":[$SHELF]}" >/dev/null; }
assign "$B1,$B2,$B3"

cat > work/kohome/koreader/settings/shelfsync.lua <<EOF
return {
    ["home_url"] = "http://unreachable.invalid:6060",
    ["away_url"] = "http://grimmory:6060",
    ["username"] = "$USER",
    ["password"] = "$PASS",
    ["shelf_id"] = $SHELF,
    ["shelf_name"] = "Kindle",
    ["folder"] = "/kohome/books/Grimmory",
    ["min_interval_minutes"] = 0,
}
EOF

ko() { # $1 event, $2 optional file to open
  $DC --profile test run --rm -e SHELFSYNC_TEST_EVENT="$1" -e SHELFSYNC_TEST_OPEN="${2:-}" koreader 2>&1 \
    | tee -a work/koreader.log | grep -E "SHELFSYNC_TEST_RESULT|ShelfSync" | tail -5
}
has() { [[ -f "$DEV/$1" ]]; }

echo "== build koreader image"
$DC --profile test build koreader >/dev/null

echo "== round 1: wake -> first sync (home address unreachable, falls back to away)"
ko Resume
check "3 books downloaded"                  "has 'Book One [$B1].epub' && has 'Book Two.epub' && has 'Book Three.epub'"
check "user's own file left untouched"      "grep -q \"user's own file\" '$DEV/Book One.epub'"
check "downloaded bytes identical to server" "cmp -s work/books/'Book Two.epub' '$DEV/Book Two.epub'"
check "no .part leftovers"                  "! ls $DEV/*.part >/dev/null 2>&1"

echo "== server: take Two off shelf, delete Three from library, add Four and Five"
unassign "$B2"
curl -sf -X DELETE "$API/api/v1/books?ids=$B3" "${AUTH[@]}" >/dev/null
assign "$B4,$B5"

echo "== round 2: Wi-Fi connected -> mirror changes"
ko NetworkConnected
check "Two removed (taken off shelf)"       "! has 'Book Two.epub'"
check "Three removed (deleted from library)" "! has 'Book Three.epub'"
check "Four and Five added"                 "has 'Book Four.epub' && ls $DEV | grep -q 'Book Five'"
check "One still present"                   "has 'Book One [$B1].epub'"
check "user's file still untouched"         "grep -q \"user's own file\" '$DEV/Book One.epub'"

echo "== round 3: Four is open in the reader and gets taken off the shelf"
unassign "$B4"
ko Resume "/kohome/books/Grimmory/Book Four.epub"
check "open book NOT deleted"               "has 'Book Four.epub'"
check "opening created Four's .sdr sidecar"  "[[ -d '$DEV/Book Four.sdr' ]]"

echo "== round 4: book closed -> removal completes, sidecar cleaned"
ko Resume
check "Four removed after closing"          "! has 'Book Four.epub'"
check "Four's .sdr sidecar removed"         "[[ ! -d '$DEV/Book Four.sdr' ]]"
check "One and Five remain"                 "has 'Book One [$B1].epub' && ls $DEV | grep -q 'Book Five'"

echo
echo "device folder now:"; ls -la "$DEV"
echo
echo "RESULT: $pass passed, $fail failed  (full log: harness/work/koreader.log)"
[[ $fail -eq 0 ]]
