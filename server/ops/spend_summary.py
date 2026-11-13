#!/usr/bin/env python3
"""One-line daily spend summary of the assistant (Hermes). Read-only over ~/.hermes/state.db.
Run by the Hermes cron job "daily spend" (no agent: stdout is delivered as is), see hermes-cron.sh.

Balance model (optional): SPEND_BASE_BALANCE (USD) at SPEND_BASE_TIME already includes everything
spent before that moment; remaining = base - estimated spend since then. Without them the line has
no balance and counting starts at the first run.

How spend is measured:
- state.db keeps CUMULATIVE cost per (session, model, task) row. A long session that started before a
  boundary would be over-counted if attributed by timestamp, so this script stores a snapshot of every
  row's cumulative cost and counts only the increase since the previous run (state/spend_state.json).
- First run (seed): rows of sessions started after the base time count in full; for sessions that
  started earlier, the post-base share is approximated by weighting each assistant call by its context
  size (characters so far). This is an approximation and is stored as seed_approx.
- Figures are Hermes's own estimates (estimated_cost_usd), not provider invoices. Claude Code and
  other accounts are not included.
"""
import datetime as dt
import json
import os
import sqlite3
from zoneinfo import ZoneInfo
from common import STATE_DIR, conf, t

TZ = ZoneInfo(conf("SERVER_TIMEZONE", "UTC"))
BASE_BALANCE = float(conf("SPEND_BASE_BALANCE")) if conf("SPEND_BASE_BALANCE") else None
BASE_TIME = dt.datetime.fromisoformat(conf("SPEND_BASE_TIME")) if conf("SPEND_BASE_TIME") else None
HOME = os.environ.get("HERMES_HOME", os.path.expanduser("~/.hermes"))
DB = os.path.join(HOME, "state.db")
STATE = os.path.join(STATE_DIR, "spend_state.json")


def cost_of(actual, est):
    return actual if actual else (est or 0.0)


def rows(con):
    q = """select session_id||'|'||model||'|'||task, actual_cost_usd, estimated_cost_usd,
                  cache_read_tokens, cache_write_tokens, input_tokens, session_id
           from session_model_usage"""
    return {k: (cost_of(a, e), cr, cw, i, sid) for k, a, e, cr, cw, i, sid in con.execute(q)}


def post_base_fraction(con, sid):
    started = con.execute("select started_at from sessions where id=?", (sid,)).fetchone()
    if not started or started[0] >= BASE_TIME.timestamp():
        return 1.0
    ctx = before = after = 0
    for ts, role, n in con.execute(
        "select timestamp, role, coalesce(length(content),0)+coalesce(length(tool_calls),0) "
        "from messages where session_id=? order by id", (sid,)):
        ctx += n
        if role == "assistant":
            if ts >= BASE_TIME.timestamp():
                after += ctx
            else:
                before += ctx
    return after / (after + before) if (after + before) else 0.0


def main():
    now = dt.datetime.now(TZ)
    today_key, month_key = now.strftime("%Y-%m-%d"), now.strftime("%Y-%m")
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    cur = rows(con)
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    st = json.load(open(STATE)) if os.path.exists(STATE) else None
    seeded = st is None

    if seeded:
        delta = 0.0
        if BASE_TIME:  # without a base time, the first run only takes the snapshot
            for k, (c, *_rest, sid) in cur.items():
                last = con.execute("select max(last_seen) from session_model_usage "
                                   "where session_id||'|'||model||'|'||task=?", (k,)).fetchone()[0]
                if last and last >= BASE_TIME.timestamp():
                    delta += c * post_base_fraction(con, sid)
        st = {"snap": {}, "since_base": 0.0, "days": {}, "months": {}, "seed_approx": round(delta, 4)}
    else:
        delta = sum(max(0.0, v[0] - st["snap"].get(k, [0.0])[0]) for k, v in cur.items())

    # cache-hit over the same increment (tokens)
    d_cr = sum(max(0, v[1] - st["snap"].get(k, [0, 0, 0, 0])[1]) for k, v in cur.items()) if not seeded else 0
    d_cw = sum(max(0, v[2] - st["snap"].get(k, [0, 0, 0, 0])[2]) for k, v in cur.items()) if not seeded else 0
    d_in = sum(max(0, v[3] - st["snap"].get(k, [0, 0, 0, 0])[3]) for k, v in cur.items()) if not seeded else 0

    st["since_base"] += delta
    st["days"][today_key] = st["days"].get(today_key, 0.0) + delta
    st["months"][month_key] = st["months"].get(month_key, 0.0) + delta
    st["snap"] = {k: list(v[:4]) for k, v in cur.items()}
    st["updated"] = now.isoformat()
    json.dump(st, open(STATE, "w"), indent=1)

    tot = d_cr + d_cw + d_in
    hit = f"{100 * d_cr / tot:.0f}%" if tot else "n/a"
    left = t("spend_left", left=BASE_BALANCE - st["since_base"]) if BASE_BALANCE is not None else ""
    since = t("spend_since", hhmm=BASE_TIME.astimezone(TZ).strftime("%H:%M")) if BASE_TIME else ""
    print(t("spend", today=st["days"][today_key], month=st["months"][month_key], left=left, hit=hit, since=since))


if __name__ == "__main__":
    main()
