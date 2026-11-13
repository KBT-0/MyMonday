#!/usr/bin/env python3
"""Poll the workstation's lead events (ssh workstation lead events OFFSET) and push them to Telegram.
Cron: every minute (server/ops/crontab.in, killed after 50 s; this script stops new work at ~42 s).

Events come from ~/.claude/notify.sh on the workstation (claude running in the tmux session "leads"):
  {"ts": epoch, "lead": name, "event": permission|question|stop|failure|ended|prompt|answered, "msg": ...}
`lead list` (one line per lead: name state mode running last-state age) gives the registered leads and
their current hook state; it drives the reminders and the crash notice, so no heavy `status --json`.

MODE (state/lead_watch.mode, one word):
  full        permission / question / stop / failure / ended   (default; keep it: CCGram's own pushes
              are usually muted, so these pings are the owner's only alerts)
  escalation  only failure / ended
WORK MODE (state/work_mode): "1" = the owner works through Telegram (notify everything at once),
  "2" = the owner sits at the Mac terminals: only failure/ended at once; a finished turn is reported
  after 15 min without a new prompt, questions/permissions through the 15-min reminder. Mode 2 starts
  when the file is written (its mtime). It ends by itself (back to 1, with a message naming who waits)
  when the Mac drops off the tailnet, or when a lead really waits on the owner 30+ min: a question or
  permission prompt, or a finished turn whose screen shows nothing running. Only waits that began
  after mode 2 started count.

Rules: only registered leads; events older than MAX_AGE are dropped (e.g. after a wake); a later
'prompt'/'answered' cancels an earlier waiting event; no screen dumps (privacy; CCGram has the detail).
Delivery: every notice goes to an outbox saved in the state file together with the event offset, then
is sent; a failed send stays queued and is retried next run (dropped after OUTBOX_MAX_AGE), so a
Telegram error never loses an event and a crash never repeats one.
The workstation off/asleep (ssh rc 255) is silent; if Tailscale still shows the workstation online while ssh
fails for 30+ min, one notice. Limitation: when Tailscale itself is down on the workstation an ssh
breakage looks like "off" and stays silent. 3 consecutive other failures -> one alert.
Mute: lead names or `all` in state/lead_watch.mute.
"""
import fcntl, json, os, re, subprocess, time
from common import STATE_DIR, conf, ssh_workstation, t
from common import notify as _send

S = STATE_DIR
STATE, LOCK = f"{S}/lead_watch.json", f"{S}/lead_watch.lock"
MUTE_FILE, MODE_FILE = f"{S}/lead_watch.mute", f"{S}/lead_watch.mode"
WORK_MODE_FILE = f"{S}/work_mode"
MAC_IP, MAC_PREFIX = conf("MAC_HOST"), conf("MAC_HOSTNAME_PREFIX", "macbook").lower()
WORKSTATION_IP = conf("WORKSTATION_HOST")
MAX_AGE = 30 * 60            # older events are not pushed
DELAY = 15 * 60              # mode 2: a finished turn is reported after this
WAIT_EXIT = 30 * 60          # mode 2 ends when a lead waits this long
REMIND_FIRST, REMIND_EVERY = 15 * 60, 30 * 60
UNREACH = 30 * 60            # workstation online on the tailnet, ssh failing: one notice after this
OUTBOX_MAX_AGE = 6 * 3600
DEADLINE_S = 42              # cron's timeout is 50 s
EVENTS = ("permission", "question", "stop", "failure", "ended")
MODES = {"full": set(EVENTS), "escalation": {"failure", "ended"}}
WAITING = ("waiting_question", "waiting_permission")
BUSY_RE = re.compile(r"still running|esc to interrupt|agents running|[✻✶✳✢·*] \w+… ?\(")

_T0 = time.monotonic()


def left():
    """Seconds left before this run must stop starting new network calls."""
    return DEADLINE_S - (time.monotonic() - _T0)


def ssh(*args, timeout=15):
    tmo = min(timeout, left())
    if tmo < 3:
        raise subprocess.TimeoutExpired("ssh", 0)
    return ssh_workstation(*args, timeout=tmo)


def log(text):
    with open(f"{S}/lead_watch.log", "a") as f:
        f.write(time.strftime("%F %T ") + text.replace("\n", " | ")[:300] + "\n")


def send(text):
    """Telegram, bounded by the run's deadline."""
    _send(text, timeout=max(2, min(10, left())))


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def readf(p, default=""):
    try:
        with open(p) as f:
            return f.read().strip()
    except FileNotFoundError:
        return default


def load():
    try:
        with open(STATE) as f:
            st = json.load(f)
    except (FileNotFoundError, ValueError):
        st = {}
    for k, v in (("offset", 0), ("last", {}), ("fails", 0), ("delayed", {}), ("remind", {}),
                 ("crashed", {}), ("outbox", [])):
        st.setdefault(k, v)
    return st


def save(st):
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(st, f)
    os.replace(tmp, STATE)


def queue(st, text, now=None):
    st["outbox"].append({"ts": now or time.time(), "text": text})


def flush(st, sender=None):
    """Send the outbox in order; stop at the first failure (kept for the next run). Saves after each."""
    sender = sender or send
    now = time.time()
    box = st["outbox"]
    for m in [m for m in box if now - m.get("ts", now) > OUTBOX_MAX_AGE]:
        log("dropped (undelivered for hours): " + m.get("text", ""))
        box.remove(m)
    while box and left() > 3:
        try:
            sender(box[0]["text"])
        except Exception as e:  # noqa: BLE001 - network or Telegram error: retry next run
            log(f"send failed ({type(e).__name__}); {len(box)} queued")
            break
        log(box.pop(0)["text"])
        save(st)
    save(st)


AGE_RE = re.compile(r"(\d+)([smhd])")


def parse_age(s):
    m = AGE_RE.fullmatch(s or "")
    return int(m[1]) * {"s": 1, "m": 60, "h": 3600, "d": 86400}[m[2]] if m else None


def parse_list(text):
    """`lead list` -> {name: {state, run, last, age}}; last is the hook state (None when unknown)."""
    out = {}
    for line in text.splitlines():
        f = line.split()
        if not f:
            continue
        f += [""] * (6 - len(f))
        out[f[0]] = {"state": f[1], "run": f[3], "last": None if f[4] in ("", "-") else f[4],
                     "age": parse_age(f[5])}
    return out


def parse_events(text, offset):
    events, new_off = [], offset
    for line in text.splitlines():
        if line.startswith("OFFSET "):
            try:
                new_off = int(line.split()[1])
            except (IndexError, ValueError):
                pass
            continue
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if isinstance(e, dict):
            events.append(e)
    return events, new_off


def muted(name, mute):
    return "all" in mute or name in mute


def classify(events, leads, mute, wanted, mode2, now, delayed):
    """-> {lead: latest event to push now}. In mode 2 stop events go to `delayed` instead."""
    pending = {}
    for e in events:
        lead, ev = e.get("lead"), e.get("event")
        if lead not in leads or muted(lead, mute):
            continue
        if ev in ("prompt", "answered"):
            pending.pop(lead, None); delayed.pop(lead, None); continue
        if ev == "stop" and e.get("bg"):  # turn ended with background work running: not waiting
            pending.pop(lead, None); delayed.pop(lead, None); continue
        ts = num(e.get("ts"))
        age = now - ts if ts is not None else MAX_AGE + 1
        if mode2 and ev == "stop":
            if age <= 2 * 3600:
                delayed[lead] = e
            continue
        if ev in wanted and age <= MAX_AGE:
            pending[lead] = e
    return pending


def text_of(lead, e):
    txt = f'[{lead}] {t("ev_" + e["event"])}'
    if e.get("msg"):
        txt += f'\n{str(e["msg"])[:200]}'
    return txt


def busy_on_screen(lead):
    """True if the lead's screen shows it is still working (spinner, background shell or agents).
    A turn can end while a background worker runs; that lead is not waiting on the owner."""
    try:
        rc, out = ssh("read", lead, "25", timeout=10)
    except subprocess.TimeoutExpired:
        return True  # unsure: do not act
    return rc != 0 or bool(BUSY_RE.search(out))


def process_delayed(st, now, busy):
    """Mode 2 (and leftovers after it): a finished turn with no new prompt for DELAY -> one notice,
    unless the screen shows work still running. Entries stay (until a prompt or 6 h) for mode-2 exit."""
    delayed = st["delayed"]
    for lead, e in list(delayed.items()):
        ts = num(e.get("ts"))
        if ts is None or now - ts > 6 * 3600:
            delayed.pop(lead, None); continue
        age = now - ts
        key = f'stop:{e.get("ts")}'
        if age < DELAY or st["last"].get(lead) == key:
            continue
        st["last"][lead] = key
        if busy(lead):
            continue  # still working in the background: no "waiting" notice
        txt = t("stop_delayed", lead=lead, mins=int(age // 60))
        if e.get("msg"):
            txt += f'\n{str(e["msg"])[:200]}'
        queue(st, txt, now)


def remind(st, states, mute, now):
    """A lead still waiting on a question/permission (its `lead list` state): remind after 15 min, then
    every 30 min (both work modes; in mode 2 this is the only question/permission notice)."""
    rem = st["remind"]
    for name in list(rem):
        if name not in states:
            rem.pop(name)
    for name, x in states.items():
        if muted(name, mute) or x["last"] not in WAITING or x["run"] != "yes":
            rem.pop(name, None); continue
        r = rem.get(name)
        if not r or r.get("kind") != x["last"]:
            since = now - x["age"] if x["age"] is not None else now
            r = rem[name] = {"since": since, "last": 0, "kind": x["last"]}
        waited = now - r["since"]
        if waited >= REMIND_FIRST and now - r["last"] >= REMIND_EVERY:
            what = t("kind_question") if x["last"] == "waiting_question" else t("kind_permission")
            queue(st, t("remind", lead=name, mins=int(waited // 60), what=what), now)
            r["last"] = now


def crashed(st, states, mute, now):
    """An active lead whose claude is gone (dead pane) without a session-end event: one notice."""
    seen = st["crashed"]
    for name in list(seen):
        if name not in states or states[name]["run"] != "dead":
            seen.pop(name)
    for name, x in states.items():
        if (x["state"] == "active" and x["run"] == "dead" and x["last"] not in (None, "ended")
                and name not in seen and not muted(name, mute)):
            seen[name] = now
            queue(st, t("lead_crashed", lead=name), now)


def mode2_since(st):
    """Start of the current mode-2 session (mtime of work_mode). A new session drops the finished-turn
    waits from before it, so an old entry can never end it at the first check."""
    try:
        since = os.path.getmtime(WORK_MODE_FILE)
    except OSError:
        since = st.get("mode2_since") or time.time()
    if st.get("mode2_since") != since:
        st["mode2_since"] = since
        st["delayed"] = {n: e for n, e in st["delayed"].items() if (num(e.get("ts")) or 0) >= since}
    return since


def mode2_waits(st, now, since, busy):
    """Leads really waiting on the owner WAIT_EXIT+ in mode 2, waits begun after `since` only:
    question/permission waits always count; finished turns only when the screen shows nothing running."""
    asked = {n for n, r in st["remind"].items()
             if r.get("since", now) >= since and now - r["since"] >= WAIT_EXIT}
    done = sorted(n for n, e in st["delayed"].items()
                  if n not in asked and (num(e.get("ts")) or 0) >= since and now - num(e.get("ts")) >= WAIT_EXIT)
    return sorted(asked | {n for n in done if not busy(n)})


_peers = None


def peers():
    """Tailscale peers as this server sees them (one call per run; costs nothing on the peers)."""
    global _peers
    if _peers is None:
        _peers = []
        try:
            tmo = min(10, left())
            if tmo >= 2:
                r = subprocess.run(["tailscale", "status", "--json"], capture_output=True, text=True, timeout=tmo)
                if r.returncode == 0:
                    _peers = list((json.loads(r.stdout).get("Peer") or {}).values())
        except (subprocess.TimeoutExpired, ValueError, OSError):
            pass
    return _peers


def mac_offline():
    """True when Tailscale sees the Mac offline: an asleep or closed Mac drops off within minutes."""
    mac = [p for p in peers() if (MAC_PREFIX and p.get("HostName", "").lower().startswith(MAC_PREFIX))
           or (MAC_IP and MAC_IP in p.get("TailscaleIPs", []))]
    return bool(mac) and not mac[0].get("Online", False)


def workstation_online():
    return bool(WORKSTATION_IP) and any(WORKSTATION_IP in p.get("TailscaleIPs", []) and p.get("Online") for p in peers())


def check_mode2_exit(st, now, up, busy):
    """Every 2 min in mode 2: leave it when the Mac is offline or (workstation up) a lead waits WAIT_EXIT+."""
    if readf(WORK_MODE_FILE, "1") != "2" or now - st.get("mac_check", 0) <= 120:
        return
    st["mac_check"] = now
    since = mode2_since(st)
    waits = mode2_waits(st, now, since, busy) if up else []
    why = t("mac_offline") if mac_offline() else t("lead_waits_30", names=", ".join(waits)) if waits else None
    if not why:
        return
    with open(WORK_MODE_FILE, "w") as f:
        f.write("1\n")
    st.pop("mode2_since", None)
    # who is waiting right now: finished turns not reported yet are named here, then done with
    waiting = set(st["remind"])
    for lead, e in list(st["delayed"].items()):
        key = f'stop:{e.get("ts")}'
        if st["last"].get(lead) != key:
            waiting.add(lead)
            st["last"][lead] = key
    st["delayed"] = {}
    msg = t("mode1_back", why=why)
    if waiting:
        msg += "\n" + t("waiting_now", names=", ".join(sorted(waiting)))
    queue(st, msg, now)


def main():
    os.makedirs(S, exist_ok=True)
    with open(LOCK, "w") as lf:
        try:
            fcntl.flock(lf, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        run()


def run():
    st = load()
    flush(st)  # what an earlier run could not send goes first
    now = time.time()
    mode2 = readf(WORK_MODE_FILE, "1") == "2"
    if mode2:
        mode2_since(st)
    else:
        st.pop("mode2_since", None)
    wanted = MODES["escalation"] if mode2 else MODES.get(readf(MODE_FILE, "full"), MODES["full"])
    try:
        rc, out = ssh("lead", "events", str(st["offset"]))
        rc2, lst = ssh("lead", "list") if rc == 0 else (rc, "")
    except subprocess.TimeoutExpired:
        rc, out, rc2, lst = 1, "", 1, ""
    if rc == 255:  # workstation off / asleep, or ssh broken: told apart through Tailscale
        st["fails"] = 0
        if workstation_online():
            st.setdefault("unreach_since", now)
            if now - st["unreach_since"] >= UNREACH and not st.get("unreach_told"):
                queue(st, t("ssh_broken", mins=int((now - st["unreach_since"]) // 60)), now)
                st["unreach_told"] = True
        else:
            st.pop("unreach_since", None); st.pop("unreach_told", None)
        check_mode2_exit(st, now, False, busy_on_screen)
        save(st); flush(st); return
    st.pop("unreach_since", None); st.pop("unreach_told", None)
    if rc != 0 or rc2 != 0:
        st["fails"] += 1
        if st["fails"] == 3:
            queue(st, t("events_unreadable", rc=rc, rc2=rc2), now)
        check_mode2_exit(st, now, False, busy_on_screen)
        save(st); flush(st); return
    st["fails"] = 0
    states = parse_list(lst)
    events, new_off = parse_events(out, st["offset"])
    mute = {l.strip() for l in readf(MUTE_FILE).splitlines() if l.strip()}
    pending = classify(events, set(states), mute, wanted, mode2, now, st["delayed"])
    for lead, e in pending.items():
        key = f'{e.get("event")}:{e.get("ts")}'
        if st["last"].get(lead) != key:
            queue(st, text_of(lead, e), now)
            st["last"][lead] = key
    # a lead that is working again (an event was missed) is no longer a finished turn
    for lead in list(st["delayed"]):
        if lead not in states or states[lead]["last"] == "working":
            st["delayed"].pop(lead)
    st["offset"] = new_off if new_off >= st["offset"] else 0
    save(st)  # offset and the queued notices together
    process_delayed(st, now, busy_on_screen)
    remind(st, states, mute, now)
    crashed(st, states, mute, now)
    check_mode2_exit(st, now, True, busy_on_screen)
    save(st)
    flush(st)


if __name__ == "__main__":
    main()
