#!/usr/bin/env python3
"""Vault activity watcher for the XP Union Vault.

Scans new blocks, posts one Slack line per vault event — deposit, unstake
request, unstake claim, reward claim — and appends the ledger those alerts are
derived from.

This started as tooling for the 예치왕 campaign (2026-08-12 ~ 08-25) and also
carried a daily campaign digest and a deadline snapshot. The campaign is over
and both were removed; what remains is the ordinary activity feed, which is
worth running indefinitely. The ledger and checkpoint keep their `event-`
filenames so the existing history and scan position survive the rename.

Pure stdlib on purpose. The keeper already lost a night to `cast` missing from
cron's PATH, so nothing here shells out — it speaks JSON-RPC over urllib.

Read-only: no private key is used or needed.
"""

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
LEDGER = os.path.join(STATE_DIR, "event-ledger.jsonl")
CHECKPOINT = os.path.join(STATE_DIR, "event-checkpoint.json")

RPC = os.environ.get("RPC", "https://rpc.ankr.com/xphere_mainnet")
VAULT = (os.environ.get("VAULT") or "").lower()
SLACK = os.environ.get("SLACK_WEBHOOK", "")


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
SEL_BALANCE_OF = "0x70a08231"

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
    """First block at or after `target` (unix seconds), by bisection."""
    hi = block_number() if hi is None else hi
    lo = 0 if lo is None else lo
    while lo < hi:
        mid = (lo + hi) // 2
        if block_time(mid) < target:
            lo = mid + 1
        else:
            hi = mid
    return lo


def call(to, data, block="latest"):
    tag = block if isinstance(block, str) else hex(block)
    return rpc("eth_call", [{"to": to, "data": data}, tag])


def addr_arg(a):
    return a.lower().replace("0x", "").rjust(64, "0")


def balance_of(who, block="latest"):
    return int(call(VAULT, SEL_BALANCE_OF + addr_arg(who), block) or "0x0", 16)


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


def pname(pid):
    return PARTNER_NAME.get(pid, pid[:10] + "…")


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
        # Default to the head: a fresh install alerts on what happens next, not
        # on months of history. Backfill after losing state/ with one of:
        #   --from-block=N   exact block
        #   --from-days=N    N days back, resolved by bisection
        anchor = head
        for a in argv:
            if a.startswith("--from-block="):
                anchor = int(a.split("=", 1)[1]) - 1
            elif a.startswith("--from-days="):
                anchor = block_at_time(int(time.time()) - 86400 * int(a.split("=", 1)[1])) - 1
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


def main():
    if not VAULT:
        sys.exit("VAULT is not set — source ops/.env first")
    if len(sys.argv) < 2 or sys.argv[1] != "watch":
        sys.exit(f"usage: {sys.argv[0]} watch [--quiet] [--from-block=N|--from-days=N]")
    cmd_watch(sys.argv[2:])


if __name__ == "__main__":
    main()
