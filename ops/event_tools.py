#!/usr/bin/env python3
"""Event-campaign watcher and reporter for the XP Union Vault.

Three jobs, one file:

  watch     scan new blocks, post one Slack line per vault event, append the
            ledger that everything else is derived from
  report    daily digest for the team while the campaign runs
  snapshot  final list of stakers and balances at the campaign deadline,
            written as CSV for the manual reward selection

Pure stdlib on purpose. The keeper already lost a night to `cast` missing from
cron's PATH, so nothing here shells out — it speaks JSON-RPC over urllib.

Read-only: no private key is used or needed.
"""

import csv
import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

KST = timezone(timedelta(hours=9))

HERE = os.path.dirname(os.path.abspath(__file__))
STATE_DIR = os.path.join(HERE, "state")
OUT_DIR = os.path.join(HERE, "out")
LEDGER = os.path.join(STATE_DIR, "event-ledger.jsonl")
CHECKPOINT = os.path.join(STATE_DIR, "event-checkpoint.json")

RPC = os.environ.get("RPC", "https://rpc.ankr.com/xphere_mainnet")
VAULT = (os.environ.get("VAULT") or "").lower()
SLACK = os.environ.get("SLACK_WEBHOOK", "")

# Campaign window, KST in the booking, UTC here.
EVENT_START = int(os.environ.get("EVENT_START", "1786518000"))  # 8/12 16:00 KST
EVENT_END = int(os.environ.get("EVENT_END", "1787670000"))  # 8/25 24:00 KST

# Precomputed so the server needs no keccak implementation.
TOPIC = {
    "0xc6daf3f44b892b946e8f054dee61a5c544673a355b8ec6fd0ba713e6e67518db": "deposit",
    "0x239fbfa6360369e94e48015ee485dafe887b4c10e282a9a6a2dc826fa97efc2f": "unstake_request",
    "0xeabfc30078ce0948bb3121c1cf0e6cab35bb87a3d40d5e646d4b4fe9dd6e80ae": "unstake_claim",
    "0xc451967880ae6293c5a4c3ed397a45e0c39860af769a5370c769f86ceb320927": "reward_claim",
}
PARTNER_NAME = {
    # keccak256(slug). Precomputed for the same reason as the topics above.
    "0xdadd67f7e8e4dfc56f02113abcea30682a957db2c231541dfda8f31341f6a89d": "ankr",
    "0xbd4a27a336aa80072fb6cb9d989741cf0bc107987acb1af8374046ca440362c1": "nansen",
    # keccak256("DIRECT") — the contract's bucket for deposits with no referral.
    "0xfb59ab348c9b985b58c338de98118b538ac0cdc9cce2ca7e05e581e6ccfda190": "직접유입",
    "0x" + "0" * 64: "(미귀속)",
}
DIRECT = "0xfb59ab348c9b985b58c338de98118b538ac0cdc9cce2ca7e05e581e6ccfda190"

SEL_BALANCE_OF = "0x70a08231"
SEL_USER_PARTNER = "0xf90a0de7"

MAX_SPAN = 1000  # the public RPC rejects wider getLogs ranges
SHARE_UNIT = 1000  # 1 XP == 1000 shares, fixed in the contract


# ── plumbing ────────────────────────────────────────────────────────────────
def rpc(method, params, tries=4):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
    last = None
    for attempt in range(tries):
        try:
            req = urllib.request.Request(
                RPC, body.encode(), {"Content-Type": "application/json", "User-Agent": "xp-vault-event/1.0"}
            )
            with urllib.request.urlopen(req, timeout=30) as r:
                out = json.load(r)
            if "error" in out:
                raise RuntimeError(out["error"])
            return out["result"]
        except Exception as e:  # noqa: BLE001 — retry anything, the RPC rate-limits
            last = e
            time.sleep(1.5 * (attempt + 1))
    raise RuntimeError(f"RPC {method} failed after {tries} tries: {last}")


def block_number():
    return int(rpc("eth_blockNumber", []), 16)


def block_time(n):
    b = rpc("eth_getBlockByNumber", [hex(n), False])
    return int(b["timestamp"], 16)


def block_at_time(target, lo=None, hi=None):
    """First block at or after `target`. Xphere is ~1s/block but never assume."""
    hi = hi if hi is not None else block_number()
    lo = lo if lo is not None else max(1, hi - 3_000_000)
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if block_time(mid) < target:
            lo = mid
        else:
            hi = mid
    return hi


def call(to, data, block="latest"):
    tag = block if isinstance(block, str) else hex(block)
    return rpc("eth_call", [{"to": to, "data": data}, tag])


def addr_arg(a):
    return a.lower().replace("0x", "").rjust(64, "0")


def balance_of(who, block="latest"):
    return int(call(VAULT, SEL_BALANCE_OF + addr_arg(who), block) or "0x0", 16)


def user_partner(who, block="latest"):
    return "0x" + (call(VAULT, SEL_USER_PARTNER + addr_arg(who), block) or "0x0")[2:].rjust(64, "0")


def notify(text):
    if not SLACK:
        print(text)
        return
    try:
        req = urllib.request.Request(
            SLACK, json.dumps({"text": text}).encode(), {"Content-Type": "application/json"}
        )
        urllib.request.urlopen(req, timeout=10)
    except Exception as e:  # noqa: BLE001 — never let alerting break the job
        print("slack failed:", e, file=sys.stderr)


def xp(wei):
    return int(wei) / 1e18


def fmt(wei, dp=4):
    """Fixed decimals, except when that would round a real amount to zero.

    Reward claims from dust stakes land in the 1e-5 range, and printing those
    as "0.0000 XP" reads as a broken alert rather than a small one. Below the
    chosen precision, show enough digits for the figure to survive."""
    v = xp(wei)
    if v != 0 and abs(v) < 10 ** -dp:
        return f"{v:,.10f}".rstrip("0")
    return f"{v:,.{dp}f}"


def kst(ts):
    return datetime.fromtimestamp(ts, KST).strftime("%m-%d %H:%M")


def short(a):
    return a[:6] + "…" + a[-4:]


def pname(pid):
    return PARTNER_NAME.get(pid, pid[:10] + "…")


# ── ledger ──────────────────────────────────────────────────────────────────
def load_ledger():
    if not os.path.exists(LEDGER):
        return []
    rows = []
    with open(LEDGER, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def append_ledger(rows):
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(LEDGER, "a", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")


def read_checkpoint(default_block):
    if os.path.exists(CHECKPOINT):
        with open(CHECKPOINT, encoding="utf-8") as f:
            return json.load(f).get("lastBlock", default_block)
    return default_block


def write_checkpoint(n):
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(CHECKPOINT, "w", encoding="utf-8") as f:
        json.dump({"lastBlock": n, "updated": datetime.now(timezone.utc).isoformat()}, f)


# ── decoding ────────────────────────────────────────────────────────────────
def topic_addr(t):
    return "0x" + t[-40:]


def words(data):
    d = data[2:] if data.startswith("0x") else data
    return [d[i : i + 64] for i in range(0, len(d), 64)]


def decode(log):
    kind = TOPIC.get(log["topics"][0])
    if not kind:
        return None
    w = words(log["data"])
    base = {
        "kind": kind,
        "block": int(log["blockNumber"], 16),
        "tx": log["transactionHash"],
    }
    if kind == "deposit":
        # Deposited(sender indexed, receiver indexed, assets, shares, partnerId indexed)
        base.update(
            who=topic_addr(log["topics"][2]),
            partner="0x" + log["topics"][3][2:],
            assets=int(w[0], 16),
        )
    elif kind == "unstake_request":
        # RedeemRequested(owner indexed, controller indexed, requestId indexed,
        #                 shares, assets, claimableAt, partnerId)
        base.update(
            who=topic_addr(log["topics"][1]),
            requestId=int(log["topics"][3], 16),
            assets=int(w[1], 16),
            claimableAt=int(w[2], 16),
            partner="0x" + w[3],
        )
    elif kind == "unstake_claim":
        base.update(
            who=topic_addr(log["topics"][1]),
            requestId=int(log["topics"][3], 16),
            assets=int(w[0], 16),
        )
    elif kind == "reward_claim":
        base.update(who=topic_addr(log["topics"][1]), assets=int(w[0], 16))
    return base


LINE = {
    "deposit": ("💰", "스테이킹"),
    "unstake_request": ("📤", "언스테이킹 요청"),
    "unstake_claim": ("✅", "인출 완료"),
    "reward_claim": ("🎁", "보상 수령"),
}


# Verified with `cast sig` — a wrong selector reads as zero, not as an error,
# so a totals block would quietly show 0 XP instead of failing.
SEL_TOTAL_ASSETS = "0x01e1d114"  # totalAssets()
SEL_STAKE_CAP = "0xba28fd2e"  # stakeCap()
SEL_PENDING_REDEEM = "0x25bb3361"  # totalPendingRedeem()
SEL_REWARD_RESERVES = "0xf0de8228"  # rewardReserves()


def vault_state():
    """Totals worth carrying on every alert. Returns None if a read fails —
    an alert without the summary still beats no alert."""
    try:
        g = lambda sel: int(call(VAULT, sel) or "0x0", 16)
        return {
            "tvl": g(SEL_TOTAL_ASSETS),
            "cap": g(SEL_STAKE_CAP),
            "pendingRedeem": g(SEL_PENDING_REDEEM),
            "reserves": g(SEL_REWARD_RESERVES),
        }
    except Exception:  # noqa: BLE001
        return None


def state_block(s):
    if not s:
        return ""
    pct = f" ({s['tvl'] / s['cap'] * 100:.2f}%)" if s["cap"] else ""
    return (
        "\n📊 현황"
        f"\n  총 스테이킹  {fmt(s['tvl'], 2)} XP{pct}"
        f"\n  인출 대기    {fmt(s['pendingRedeem'], 2)} XP"
        f"\n  이자 대기    {fmt(s['reserves'], 2)} XP"
    )


def describe(ev, ts, state=None):
    icon, label = LINE[ev["kind"]]
    lines = [f"{icon} [XP Vault] {label}", f"지갑: `{ev['who']}`", f"수량: {fmt(ev['assets'])} XP"]
    if ev.get("partner"):
        lines.append(f"파트너: {pname(ev['partner'])}")
    if ev["kind"] == "unstake_request":
        lines.append(f"청구 가능: {kst(ev['claimableAt'])} KST")
    if ev["kind"] == "deposit":
        try:
            lines.append(f"해당 지갑 총 예치: {fmt(balance_of(ev['who']) // SHARE_UNIT)} XP")
        except Exception:  # noqa: BLE001 — a failed read must not drop the alert
            pass
    lines.append(f"{kst(ts)} KST · 블록 {ev['block']}")
    return "\n".join(lines) + state_block(state)


# ── commands ────────────────────────────────────────────────────────────────
def cmd_watch(argv):
    quiet = "--quiet" in argv  # backfill without spamming the channel
    head = block_number()

    # The checkpoint has to be written on the very first run, even when there
    # is nothing to scan. Returning early without one meant every later run
    # re-defaulted to the current head, so the file never appeared and no block
    # was ever scanned — the watcher stayed silent forever.
    if not os.path.exists(CHECKPOINT):
        anchor = block_at_time(EVENT_START) - 1 if "--from-event" in argv else head
        write_checkpoint(anchor)
        print(f"checkpoint initialised at {anchor}")

    frm = read_checkpoint(head) + 1
    if frm > head:
        print(f"nothing new (checkpoint {frm - 1}, head {head})")
        return

    seen = 0
    cur = frm
    while cur <= head:
        end = min(cur + MAX_SPAN - 1, head)
        logs = rpc(
            "eth_getLogs",
            [{"fromBlock": hex(cur), "toBlock": hex(end), "address": VAULT, "topics": [list(TOPIC)]}],
        )
        chunk = []
        for lg in logs:
            ev = decode(lg)
            if not ev:
                continue
            ev["ts"] = block_time(ev["block"])
            chunk.append(ev)

        # Persist this chunk BEFORE advancing the checkpoint. The other order
        # loses every event in flight if the process dies mid-scan, and the
        # checkpoint would then skip past them forever.
        if chunk:
            append_ledger(chunk)
            seen += len(chunk)
            if not quiet:
                # One read per batch, shared by every alert in it.
                st = vault_state()
                for ev in chunk:
                    notify(describe(ev, ev["ts"], st))
        write_checkpoint(end)
        cur = end + 1
        time.sleep(0.15)

    print(f"scanned {frm}..{head}, {seen} event(s)")


def in_window(ev):
    return EVENT_START <= ev["ts"] < EVENT_END


def participants(rows):
    """Per-address campaign activity, in first-deposit order."""
    agg = {}
    for ev in rows:
        if ev["kind"] != "deposit" or not in_window(ev):
            continue
        a = agg.setdefault(
            ev["who"], {"deposited": 0, "count": 0, "first_ts": ev["ts"], "first_block": ev["block"], "partner": ev.get("partner")}
        )
        a["deposited"] += ev["assets"]
        a["count"] += 1
        if ev["ts"] < a["first_ts"]:
            a["first_ts"], a["first_block"] = ev["ts"], ev["block"]
    return dict(sorted(agg.items(), key=lambda kv: kv[1]["first_ts"]))


def cmd_report(argv):
    rows = [r for r in load_ledger() if in_window(r)]
    now = int(time.time())
    day = max(0, (now - EVENT_START) // 86400 + 1)
    total_days = (EVENT_END - EVENT_START) // 86400

    since = now - 86400
    today = [r for r in rows if r["ts"] >= since]
    parts = participants(rows)

    dep_t = sum(r["assets"] for r in today if r["kind"] == "deposit")
    unst_t = sum(r["assets"] for r in today if r["kind"] == "unstake_request")
    new_t = len({r["who"] for r in today if r["kind"] == "deposit"} - {
        r["who"] for r in rows if r["kind"] == "deposit" and r["ts"] < since
    })

    tvl = int(call(VAULT, "0x01e1d114"), 16)
    dep_all = sum(v["deposited"] for v in parts.values())

    by_partner = {}
    for who, v in parts.items():
        p = pname(v["partner"] or DIRECT)
        b = by_partner.setdefault(p, {"n": 0, "xp": 0})
        b["n"] += 1
        b["xp"] += v["deposited"]

    live = sorted(
        ((w, balance_of(w) // SHARE_UNIT) for w in parts), key=lambda kv: kv[1], reverse=True
    )

    L = [
        f"📊 [XP Vault] 이벤트 데일리 리포트 — D+{day}/{total_days}",
        f"집계: {kst(now)} KST 기준",
        f"기간: {kst(EVENT_START)} ~ {kst(EVENT_END)} KST",
        "",
        "■ 최근 24시간",
        f"  신규 참여 지갑   {new_t}개",
        f"  예치             +{fmt(dep_t, 2)} XP ({sum(1 for r in today if r['kind']=='deposit')}건)",
        f"  언스테이크 요청   -{fmt(unst_t, 2)} XP ({sum(1 for r in today if r['kind']=='unstake_request')}건)",
        f"  순증             {'+' if dep_t >= unst_t else ''}{fmt(dep_t - unst_t, 2)} XP",
        "",
        "■ 이벤트 누적",
        f"  참여 지갑        {len(parts)}개",
        f"  총 예치          {fmt(dep_all, 2)} XP",
        f"  현재 볼트 TVL     {fmt(tvl, 2)} XP",
        "",
        "■ 파트너별 (예치 기준)",
    ]
    for p, b in sorted(by_partner.items(), key=lambda kv: kv[1]["xp"], reverse=True):
        L.append(f"  {p:<10} {b['n']:>3}개   {fmt(b['xp'], 2):>14} XP")
    L += ["", "■ 예치왕 TOP 5 (현재 잔액)"]
    for i, (w, bal) in enumerate(live[:5], 1):
        L.append(f"  {i}. {short(w)}  {fmt(bal, 2):>14} XP")
    if now >= EVENT_END:
        L += ["", "⏰ 이벤트가 종료됐습니다. 최종 스냅샷은 event-report.sh snapshot 으로 생성하십시오."]
    notify("\n".join(L))


def cmd_snapshot(argv):
    """Balances at the campaign deadline — the file the reward selection uses."""
    at = EVENT_END
    for a in argv:
        if a.startswith("--at="):
            at = int(a.split("=", 1)[1])
    if int(time.time()) < at:
        print(f"deadline not reached yet ({kst(at)} KST) — refusing to snapshot early")
        return

    blk = block_at_time(at)
    rows = load_ledger()
    parts = participants(rows)
    print(f"snapshot block {blk} ({kst(block_time(blk))} KST), {len(parts)} participant(s)")

    out = []
    for rank, (who, v) in enumerate(parts.items(), 1):
        shares = balance_of(who, blk)
        out.append(
            {
                "address": who,
                "staked_xp_at_snapshot": f"{shares / SHARE_UNIT / 1e18:.6f}",
                "shares_at_snapshot": str(shares),
                "total_deposited_xp": f"{xp(v['deposited']):.6f}",
                "deposit_count": v["count"],
                "first_deposit_kst": datetime.fromtimestamp(v["first_ts"], KST).strftime("%Y-%m-%d %H:%M:%S"),
                "first_deposit_block": v["first_block"],
                "first_deposit_order": rank,
                "partner": pname(v["partner"] or DIRECT),
                "partner_id": v["partner"] or "",
            }
        )
        time.sleep(0.1)

    os.makedirs(OUT_DIR, exist_ok=True)
    stamp = datetime.fromtimestamp(at, KST).strftime("%Y%m%d-%H%M")
    path = os.path.join(OUT_DIR, f"event-snapshot-{stamp}.csv")
    with open(path, "w", newline="", encoding="utf-8-sig") as f:  # BOM: Excel opens Korean cleanly
        w = csv.DictWriter(f, fieldnames=list(out[0].keys()) if out else ["address"])
        w.writeheader()
        w.writerows(out)

    held = sorted(out, key=lambda r: float(r["staked_xp_at_snapshot"]), reverse=True)
    total_held = sum(float(r["staked_xp_at_snapshot"]) for r in out)
    L = [
        "🏁 [XP Vault] 이벤트 종료 — 최종 스냅샷",
        f"기준 시각: {kst(at)} KST (블록 {blk})",
        "",
        f"참여 지갑        {len(out)}개",
        f"스냅샷 시점 예치  {total_held:,.2f} XP",
        f"기간 총 예치액    {sum(float(r['total_deposited_xp']) for r in out):,.2f} XP",
        "",
        "■ 예치왕 TOP 10 (스냅샷 시점 잔액)",
    ]
    for i, r in enumerate(held[:10], 1):
        L.append(f"  {i:>2}. {short(r['address'])}  {float(r['staked_xp_at_snapshot']):>14,.2f} XP  [{r['partner']}]")
    L += ["", "■ 선착순 TOP 10 (최초 예치 순)"]
    for r in out[:10]:
        L.append(f"  {r['first_deposit_order']:>2}. {short(r['address'])}  {r['first_deposit_kst']}  [{r['partner']}]")
    L += ["", f"CSV: {path}", "※ 어뷰징 검토·대상자 선별은 수기로 진행됩니다."]
    notify("\n".join(L))
    print(f"\nwrote {path}")


def main():
    if not VAULT:
        sys.exit("VAULT is not set — source ops/.env first")
    cmds = {"watch": cmd_watch, "report": cmd_report, "snapshot": cmd_snapshot}
    if len(sys.argv) < 2 or sys.argv[1] not in cmds:
        sys.exit(f"usage: {sys.argv[0]} {{{'|'.join(cmds)}}} [options]")
    cmds[sys.argv[1]](sys.argv[2:])


if __name__ == "__main__":
    main()
