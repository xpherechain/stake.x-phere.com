#!/usr/bin/env bash
# ============================================================
# 정산 직후 일별 통계를 web/data/stats.json 에 기록하고 repo에 push.
# daily-settle.sh 가 settle 성공 시 자동 호출한다.
#
# 전제: 서버의 /opt/xp-vault 가 push 가능한 git clone 일 것
#       (GitHub Deploy Key — write access — 등록 필요. SETUP.md 참고)
#       clone 이 아니거나 push 실패해도 정산 자체엔 영향 없음(로그만 남김).
# ============================================================
set -euo pipefail
cd "$(dirname "$0")"
# foundry(cast)를 어떤 실행 환경에서도 찾도록 PATH 보강
# (cron, sudo -u 는 로그인 셸을 거치지 않아 ~/.foundry/bin 이 빠진다)
export PATH="$PATH:$HOME/.foundry/bin:/home/xpops/.foundry/bin:/usr/local/bin"
set -a; source ./.env; set +a
: "${RPC:?}"; : "${DIST:?}"; : "${VAULT:?}"
REPO_DIR="$(cd .. && pwd)"
STATS="$REPO_DIR/web/data/stats.json"
[ -f "$STATS" ] || { echo "stats.json not found ($STATS) — skip"; exit 0; }

c() { cast call "$1" "$2" --rpc-url "$RPC"; }

# One read per value, retried. The RPC rate-limits bursts, and an empty
# result here used to reach python as an empty argv and abort the whole
# script before the commit — losing the day silently.
read_retry() {
  local out i
  for i in 1 2 3; do
    out=$(c "$1" "$2" 2>/dev/null) && [ -n "$out" ] && { printf '%s' "$out"; return 0; }
    sleep 2
  done
  echo "RPC read failed after 3 tries: $2" >&2
  return 1
}

# lastSettlement: (settledAt, totalAmount, burned, distributed) — one call, four lines.
SETTLEMENT=$(read_retry "$DIST" "lastSettlement()(uint64,uint256,uint256,uint256)")
SETTLED_AT=$(echo "$SETTLEMENT" | sed -n 1p | awk '{print $1}')
TOTAL=$(echo "$SETTLEMENT"       | sed -n 2p | awk '{print $1}')
BURNED=$(echo "$SETTLEMENT"      | sed -n 3p | awk '{print $1}')
DISTED=$(echo "$SETTLEMENT"      | sed -n 4p | awk '{print $1}')
TVL=$(read_retry "$VAULT" "totalAssets()(uint256)" | awk '{print $1}')
APR=$(read_retry "$VAULT" "currentAPR()(uint256)"  | awk '{print $1}')

for v in SETTLED_AT TOTAL BURNED DISTED TVL APR; do
  [ -n "${!v}" ] || { echo "empty $v — abort before touching the repo"; exit 1; }
done

# Sync to origin BEFORE writing the file, while the tree is still clean.
# The old order modified stats.json first, so `pull --rebase` always failed
# with "cannot pull with rebase: You have unstaged changes" — suppressed by
# `|| true`, so the guard against a diverged origin never actually ran, and
# once anyone else pushed, the keeper could never push again.
if git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  SALVAGE=$(cat "$STATS")           # keep entries that never made it to origin
  if git -C "$REPO_DIR" fetch -q origin main; then
    AHEAD=$(git -C "$REPO_DIR" rev-list --count FETCH_HEAD..HEAD 2>/dev/null || echo 0)
    [ "$AHEAD" != "0" ] && echo "discarding $AHEAD local commit(s) that never pushed; stats data is merged back"
    git -C "$REPO_DIR" reset -q --hard FETCH_HEAD
    printf '%s' "$SALVAGE" > "$STATS.salvage"
  else
    echo "fetch failed — continuing on the local tree"
  fi
fi

python3 - "$STATS" "$SETTLED_AT" "$TOTAL" "$BURNED" "$DISTED" "$TVL" "$APR" <<'PY'
import json, os, sys, datetime
path, ts, total, burned, disted, tvl, apr = sys.argv[1:]
ts = int(ts)
day = datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%d")
e18 = lambda v: round(int(v) / 1e18, 4)
entry = {
    "date": day, "settledAt": ts, "settled": e18(total), "burned": e18(burned),
    "distributed": e18(disted), "tvl": e18(tvl), "aprPct": round(int(apr) / 1e16, 2),
}
data = json.load(open(path))
days = {d["settledAt"]: d for d in data["days"]}

# Merge back anything a previous run recorded but never managed to push.
# Keyed by settledAt, so re-running is idempotent and the reset above
# cannot lose a day.
salvage = path + ".salvage"
if os.path.exists(salvage):
    try:
        for d in json.load(open(salvage)).get("days", []):
            days.setdefault(d["settledAt"], d)
    except Exception as e:
        print("salvage unreadable, ignoring:", e)
    os.remove(salvage)

days[ts] = entry
data["days"] = sorted(days.values(), key=lambda d: d["settledAt"])
data["updated"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump(data, open(path, "w"), indent=2)
print("recorded", entry)
PY

# Commit and push. The tree was synced to origin above, so this is a plain
# fast-forward — no rebase needed and nothing to conflict on.
if git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$REPO_DIR" add web/data/stats.json
  git -C "$REPO_DIR" -c user.name="xp-keeper" -c user.email="7077523+jabiers@users.noreply.github.com" \
    commit -m "chore(data): daily settlement stats" >/dev/null 2>&1 || true

  # Keep the push error in the log. It is the only clue when publishing
  # breaks while settlement keeps working, and swallowing it cost three days.
  if PUSH_ERR=$(git -C "$REPO_DIR" push origin main 2>&1); then
    echo "stats pushed"
  else
    echo "stats push FAILED — $(echo "$PUSH_ERR" | tail -3 | tr '\n' ' ')"
    if [ -n "${SLACK_WEBHOOK:-}" ]; then
      SLACK_WEBHOOK="$SLACK_WEBHOOK" python3 - "⚠️ [XP Vault] 통계 push 실패 — 정산은 정상이나 소각 차트가 멈춥니다. record-stats 로그를 확인해 주세요." <<'PY2' || true
import json, os, sys, urllib.request
urllib.request.urlopen(urllib.request.Request(
    os.environ["SLACK_WEBHOOK"], json.dumps({"text": sys.argv[1]}).encode(),
    {"Content-Type": "application/json"}), timeout=10)
PY2
    fi
    exit 1
  fi
else
  echo "not a git repo — stats recorded locally only"
fi
