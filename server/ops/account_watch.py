#!/usr/bin/env python3
"""account_watch: keep the workstation's Claude Code leads on an account with quota left (claude-swap).

Cron every 2 minutes. Reads `lead accounts` (cswap list --json) and `lead list` over the workstation's
forced command. Policy (all in local.env):
  ACCOUNTS_AUTO   accounts this job may switch to on its own, in order of preference (e.g. "1 2")
  ACCOUNTS_ASK    accounts used only after the owner says so (e.g. company seats): never switched to
                  here, the owner is asked once per episode and the assistant switches on his word
  ACCOUNT_5H_MAX / ACCOUNT_7D_MAX   usage % at which the active account counts as nearly spent (95 / 97)
  ACCOUNT_HARD    usage % that makes a switch urgent: done at once, mid-turn (99)
A switch moves every running claude on its next request and throws away each lead's cached context,
which is real cost (Kemal: "context yeniden üretilir, gereksiz maliyet"). So outside a genuinely urgent
case (ACCOUNT_HARD reached, or the account's login is broken and it cannot be used at all) this script
never switches by itself: it writes state/account_switch_needed.json and sends ONE notice. A monitored
Hermes cron job (see workstation skill, references/leads-system.md "Account switch, non-urgent") then
drives the handoff: ask every active lead to prepare one, wait, switch the account, then for each lead
`/clear` + paste its handoff prompt, so the new account's context is rebuilt only from that summary.
Workstation off: silent.
"""
import fcntl, json, os, subprocess, time
from common import STATE_DIR, conf, ssh_workstation, t
from common import notify as _send

S = STATE_DIR
STATE, LOCK, LOG = f"{S}/account_watch.json", f"{S}/account_watch.lock", f"{S}/account_watch.log"
NEEDED = f"{S}/account_switch_needed.json"  # read by the monitored Hermes job; this script never deletes it


def ints(key):
    return [int(x) for x in conf(key).replace(",", " ").split() if x.isdigit()]


AUTO, ASK = ints("ACCOUNTS_AUTO"), ints("ACCOUNTS_ASK")
MAX5, MAX7 = float(conf("ACCOUNT_5H_MAX", "95")), float(conf("ACCOUNT_7D_MAX", "97"))
HARD = float(conf("ACCOUNT_HARD", "99"))
# Accounts the owner wants kept in reserve: capped lower, and never switched BACK into once left
# (e.g. an account he still needs himself). Once one crosses its cap it goes into st["reserved"]
# (persisted in STATE, so it stays excluded even past a weekly reset) until he says otherwise.
PROTECT = set(ints("ACCOUNT_PROTECT"))
PROTECT_MAX = float(conf("ACCOUNT_PROTECT_MAX", "95"))


def acct_max(n):
    return (PROTECT_MAX, PROTECT_MAX) if n in PROTECT else (MAX5, MAX7)


def log(text):
    with open(LOG, "a") as f:
        f.write(time.strftime("%F %T ") + text.replace("\n", " | ")[:300] + "\n")


def notify(text):
    try:
        _send(text)
        log(text)
    except Exception as e:  # noqa: BLE001 - a failed notice must not stop a needed switch
        log(f"send failed ({type(e).__name__}): {text}")


def pcts(acc):
    u = acc.get("usage") or {}
    p5 = (u.get("fiveHour") or {}).get("pct")
    p7 = (u.get("sevenDay") or {}).get("pct")
    return (float(p5) if p5 is not None else 0.0), (float(p7) if p7 is not None else 0.0)


def usable(acc, reserved=frozenset()):
    """Quota left (under ITS OWN cap, lower for a protected account) and a working login, and not
    reserved (a protected account the owner has already pulled out of rotation)."""
    n = acc.get("number")
    if n in reserved or acc.get("usageStatus") != "ok":
        return False
    p5, p7 = pcts(acc)
    m5, m7 = acct_max(n)
    return p5 < m5 and p7 < m7


def decide(data, working, st, now):
    """-> (action, detail): account number for switch/plan, account list for ask, None otherwise.
    "switch": urgent, do it now (ACCOUNT_HARD reached, or the account is unusable: broken login).
    "plan": quota is low but not urgent: hand off to the Hermes job instead of switching here.
    "ask"/"stuck": no automatic account has quota; "wait" never happens any more (kept for tests/callers
    that may still reference it is not needed: planning replaces waiting for the non-urgent case)."""
    reserved = set(st.get("reserved", []))
    accs = {a.get("number"): a for a in data.get("accounts", [])}
    active = data.get("activeAccountNumber")
    cur = accs.get(active)
    if cur is None:
        return "none", None
    p5, p7 = pcts(cur)
    m5, m7 = acct_max(active)
    near = cur.get("usageStatus") != "ok" or p5 >= m5 or p7 >= m7
    if not near:
        st.pop("near_since", None); st.pop("asked", None); st.pop("stuck", None); st.pop("planned", None)
        return "none", None
    st.setdefault("near_since", now)
    if active in PROTECT and active not in reserved:
        reserved.add(active)  # leave it here and now, even if nothing else has quota (never finish it)
        st["reserved"] = sorted(reserved)
    cands = [n for n in AUTO if n != active and n in accs and usable(accs[n], reserved)]
    if cands:
        urgent = p5 >= HARD or p7 >= HARD or cur.get("usageStatus") != "ok"
        return ("switch" if urgent else "plan"), cands[0]
    asks = [n for n in ASK if n != active and n in accs and usable(accs[n], reserved)]
    if asks:
        return "ask", asks
    return "stuck", None


def run():
    os.makedirs(S, exist_ok=True)
    st = json.load(open(STATE)) if os.path.exists(STATE) else {}
    if not AUTO and not ASK:
        return
    try:
        rc, out = ssh_workstation("lead", "accounts", timeout=60)
    except subprocess.TimeoutExpired:
        return
    if rc != 0:
        return  # off (255) or no claude-swap: nothing to do
    try:
        data = json.loads(out)
    except ValueError:
        return
    try:
        rc2, lst = ssh_workstation("lead", "list", timeout=30)
    except subprocess.TimeoutExpired:
        rc2, lst = 1, ""
    working = rc2 != 0 or any(len(l.split()) >= 5 and l.split()[4] == "working" for l in lst.splitlines())
    now = time.time()
    active = data.get("activeAccountNumber")
    accs = {a.get("number"): a for a in data.get("accounts", [])}
    was_reserved = set(st.get("reserved", []))
    action, x = decide(data, working, st, now)
    newly_reserved = set(st.get("reserved", [])) - was_reserved
    if newly_reserved:
        notify(t("acct_reserved", accts=", ".join(map(str, sorted(newly_reserved)))))
    if action == "none" and os.path.exists(NEEDED):
        os.remove(NEEDED)  # recovered (reset, or the handoff job already switched) and theirs is stale
    if action == "switch":
        r5, r7 = pcts(accs[active]) if active in accs else (0, 0)
        try:
            rc3, res = ssh_workstation("lead", "account-switch", str(x), timeout=90)
        except subprocess.TimeoutExpired:
            rc3, res = 1, "timeout"
        if rc3 == 0:
            n5, n7 = pcts(accs[x])
            notify(t("acct_switched_urgent", old=active, new=x, o5=r5, o7=r7, n5=n5, n7=n7))
            st.clear(); st["last_switch"] = now
            try:
                os.remove(NEEDED)
            except OSError:
                pass
        elif not st.get("switch_failed"):
            notify(t("acct_switch_failed", new=x, err=res.strip()[:150]))
            st["switch_failed"] = now
    elif action == "plan":
        r5, r7 = pcts(accs[active])
        tmp = NEEDED + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"old": active, "new": x, "o5": r5, "o7": r7, "since": st["near_since"]}, f)
        os.replace(tmp, NEEDED)
        if not st.get("planned"):
            notify(t("acct_plan", old=active, new=x, o5=r5, o7=r7))
            st["planned"] = now
    elif action == "ask" and not st.get("asked"):
        r5, r7 = pcts(accs[active])
        opts = ", ".join(f"{n} (5h {pcts(accs[n])[0]:.0f}%, 7d {pcts(accs[n])[1]:.0f}%)" for n in x)
        notify(t("acct_ask", old=active, o5=r5, o7=r7, opts=opts))
        st["asked"] = now
    elif action == "stuck" and not st.get("stuck"):
        r5, r7 = pcts(accs[active])
        notify(t("acct_stuck", old=active, o5=r5, o7=r7))
        st["stuck"] = now
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(st, f)
    os.replace(tmp, STATE)


def main():
    os.makedirs(S, exist_ok=True)
    with open(LOCK, "w") as lf:
        try:
            fcntl.flock(lf, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        run()


if __name__ == "__main__":
    main()
