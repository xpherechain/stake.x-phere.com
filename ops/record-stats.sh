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
set -a; source ./.env; set +a
: "${RPC:?}"; : "${DIST:?}"; : "${VAULT:?}"
REPO_DIR="$(cd .. && pwd)"
STATS="$REPO_DIR/web/data/stats.json"
[ -f "$STATS" ] || { echo "stats.json not found ($STATS) — skip"; exit 0; }

c() { cast call "$1" "$2" --rpc-url "$RPC"; }
# lastSettlement: (settledAt, totalAmount, burned, distributed)
read -r SETTLED_AT _ < <(c "$DIST" "lastSettlement()(uint64,uint256,uint256,uint256)" | sed -n 1p | awk '{print $1}') || true
SETTLED_AT=$(c "$DIST" "lastSettlement()(uint64,uint256,uint256,uint256)" | sed -n 1p | awk '{print $1}')
TOTAL=$(c "$DIST" "lastSettlement()(uint64,uint256,uint256,uint256)" | sed -n 2p | awk '{print $1}')
BURNED=$(c "$DIST" "lastSettlement()(uint64,uint256,uint256,uint256)" | sed -n 3p | awk '{print $1}')
DISTED=$(c "$DIST" "lastSettlement()(uint64,uint256,uint256,uint256)" | sed -n 4p | awk '{print $1}')
TVL=$(c "$VAULT" "totalAssets()(uint256)" | awk '{print $1}')
APR=$(c "$VAULT" "currentAPR()(uint256)" | awk '{print $1}')

python3 - "$STATS" "$SETTLED_AT" "$TOTAL" "$BURNED" "$DISTED" "$TVL" "$APR" <<'PY'
import json, sys, datetime
path, ts, total, burned, disted, tvl, apr = sys.argv[1:]
ts = int(ts)
day = datetime.datetime.utcfromtimestamp(ts).strftime("%Y-%m-%d")
e18 = lambda v: round(int(v) / 1e18, 4)
entry = {
    "date": day, "settledAt": ts, "settled": e18(total), "burned": e18(burned),
    "distributed": e18(disted), "tvl": e18(tvl), "aprPct": round(int(apr) / 1e16, 2),
}
data = json.load(open(path))
# idempotent: replace same-timestamp entry, else append
data["days"] = [d for d in data["days"] if d["settledAt"] != ts] + [entry]
data["days"].sort(key=lambda d: d["settledAt"])
data["updated"] = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump(data, open(path, "w"), indent=2)
print("recorded", entry)
PY

# push (repo 여야만; 실패해도 정산에 영향 없음)
if git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  # origin이 앞서 있으면 push가 거부되므로 먼저 rebase (통계 append라 충돌 없음)
  git -C "$REPO_DIR" pull --rebase origin main >/dev/null 2>&1 || true
  git -C "$REPO_DIR" add web/data/stats.json
  git -C "$REPO_DIR" -c user.name="xp-keeper" -c user.email="7077523+jabiers@users.noreply.github.com" \
    commit -m "chore(data): daily settlement stats" >/dev/null 2>&1 || true
  git -C "$REPO_DIR" push origin main >/dev/null 2>&1 \
    && echo "stats pushed" || echo "stats push failed (deploy key 미설정?) — 로컬 기록만 됨"
else
  echo "not a git repo — stats recorded locally only"
fi
