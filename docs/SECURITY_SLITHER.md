# Slither 정적 분석 결과 (Phase 2)

- 도구: `slither-analyzer` 0.11.5, solc 0.8.24
- 명령: `slither . --solc-remaps @openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/ --filter-paths "lib/|test/" --exclude-dependencies`
- 결과: 27 contracts, 101 detectors, 29 results — **High/Critical 0건**. 아래는 검출 항목과 처리 판단.

| 검출기 | 위치 | 심각도 | 판단 |
|---|---|---|---|
| `divide-before-multiply` | `requestRedeem`(assets=shares/UNIT; burnShares=assets*UNIT), `notifyRewardAmount`(newRate=total/duration; dust=total−newRate*duration) | Low | **의도된 설계**. 셰어 10³ 정렬(floor)과 rate 내림 dust 캡처가 목적. 정밀도 손실이 아니라 명세된 동작 |
| `timestamp` | 쿨다운·에폭·보상 스트리밍 비교 다수 | Low | **정상**. 스테이킹 볼트의 시간 게이팅은 block.timestamp 사용이 표준(Synthetix 패턴). 조작 여지 있는 초 단위 비교 없음 |
| `low-level-calls` | 네이티브 XP 전송(settle burn, WXP.withdraw, claim*Native, sweep) | Low | **의도됨**. 네이티브 코인 전송에 필요. 전부 `nonReentrant` + CEI + 성공 체크(`NativeTransferFailed`) |
| `reentrancy-events` | `WXP.withdraw` | Low | 무해. 잔고 차감(상태 변경) 후 전송, WXP는 훅 없는 표준 토큰 |
| `incorrect-equality` | `amount == 0` (settle/canSettle) | Info | 무해. `minSettleAmount`가 0일 때의 빈 정산 방어용 이중 가드 |
| `missing-zero-check` | `setDistributor(newDistributor)` | Info | 허용. `address(0)` 설정은 sweep을 비활성(`DistributorNotSet` revert)할 뿐 자금 위험 없음. DEFAULT_ADMIN 전용 |
| `missing-inheritance` | `XPStakingVault`가 `IXPStakingVault`를 구현하지만 명시 상속 안 함 | Info | 인터페이스는 Distributor용 경량 ABI. 명시 상속 시 `totalSupply`/`totalAssets` override 충돌 관리 부담만 늘어 미채택 |
| `unindexed-event-address` | `DistributorUpdated` | Info | **수정 완료** — 주소 파라미터 indexed 처리 |

## 결론

자금 탈취·재진입(reentrancy-eth)·arbitrary-send·suicidal·uninitialized-state 등 High/Critical 검출 0건. 나머지는 전부 by-design이거나 무해 정보성 항목으로, 설계 문서(§7 보안 체크리스트)의 방어와 일치한다. 메인넷 배포 전에는 별도의 외부 감사(3rd-party audit)를 권장한다.
