#!/usr/bin/env bash
# ============================================================
# settle()만 호출. 용도:
#   - 경로 A(직접 지급): 스윕이 없으므로 이 스크립트만 돌리면 됨.
#   - 이중화: 메인 키퍼(daily-settle) 장애 대비 다른 인프라(예: GitHub Actions)에
#     이 스크립트를 하나 더 배치. permissionless라 중복 호출해도 안전(에폭당 1회만 성공).
# ============================================================
set -euo pipefail
cd "$(dirname "$0")"
set -a; source ./.env; set +a
: "${RPC:?}"; : "${DIST:?}"; : "${SETTLE_PK:?}"
log() { echo "[$(date -u +%FT%TZ)] $*"; }

READ=$(cast call "$DIST" "canSettle()(bool,string)" --rpc-url "$RPC")
OK=$(echo "$READ" | head -1 | awk '{print $1}')
if [ "$OK" = "true" ]; then
  log "settle …"
  cast send "$DIST" "settle()" --rpc-url "$RPC" --private-key "$SETTLE_PK" >/dev/null
  log "settled."
else
  log "skip: $(echo "$READ" | tail -1)"
fi
