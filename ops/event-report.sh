#!/usr/bin/env bash
# ============================================================
# 이벤트 캠페인 감시·리포트 래퍼. cron 에서 호출한다.
#
#   ./event-report.sh watch      새 블록 스캔 + 이벤트별 슬랙 알림   (5분 주기)
#   ./event-report.sh report     데일리 리포트                      (1일 1회)
#   ./event-report.sh snapshot   종료 시점 최종 스냅샷 + CSV         (종료 후 1회)
#
# 읽기 전용이다. 개인키를 쓰지 않으므로 정산 파이프라인과 완전히 분리돼 있고,
# 여기가 죽어도 정산·소각에는 영향이 없다.
# ============================================================
set -euo pipefail
cd "$(dirname "$0")"
set -a; source ./.env; set +a

# 캠페인 창(UTC). .env 에서 덮어쓸 수 있다.
: "${EVENT_START:=1786518000}"   # 2026-08-12 16:00 KST
: "${EVENT_END:=1787670000}"     # 2026-08-25 24:00 KST
export EVENT_START EVENT_END

exec python3 ./event_tools.py "$@"
