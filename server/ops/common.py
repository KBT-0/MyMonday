"""Shared helpers of the server-side ops jobs (lead_watch, spend_summary, brain_nightly).

Config: KEY=VALUE lines of local.env, looked up in this order (the process environment wins):
  $MONDAY_ENV, <this dir>/local.env (copied by the ops phase), <repo>/local.env (running from a checkout).
Telegram: bot token and home chat come from Hermes's own ~/.hermes/.env (TELEGRAM_BOT_TOKEN,
TELEGRAM_HOME_CHANNEL), so no secret is ever copied into this tree.
"""
import os
import re
import subprocess
import sys
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


def _read_env(path):
    d = {}
    try:
        for line in open(path):
            k, sep, v = line.strip().partition("=")
            if sep and re.fullmatch(r"[A-Z_][A-Z0-9_]*", k):
                d[k] = v.strip().strip('"').strip("'")
    except OSError:
        pass
    return d


def _load():
    d = {}
    for p in (os.environ.get("MONDAY_ENV"), os.path.join(HERE, "local.env"),
              os.path.join(HERE, "..", "..", "local.env")):
        if p and os.path.isfile(p):
            d = _read_env(p)
            break
    d.update({k: v for k, v in os.environ.items() if re.fullmatch(r"[A-Z_][A-Z0-9_]*", k)})
    return d


CONF = _load()


def conf(key, default=""):
    v = CONF.get(key, "")
    return v if v != "" else default


OPS_DIR = conf("OPS_DIR", HERE)
STATE_DIR = conf("OPS_STATE", os.path.join(OPS_DIR, "state"))
LANG = conf("OPS_LANG", "en")


def t(key, **kw):
    """Notification text in OPS_LANG (falls back to English)."""
    from messages import MESSAGES  # local module next to this one
    s = MESSAGES.get(LANG, {}).get(key) or MESSAGES["en"][key]
    return s.format(**kw)


def hermes_env():
    return _read_env(os.path.expanduser(os.environ.get("HERMES_ENV", "~/.hermes/.env")))


def notify(text, timeout=20):
    """Telegram sendMessage to the Hermes home channel. Raises on any error (callers queue and retry)."""
    e = hermes_env()
    data = urllib.parse.urlencode({"chat_id": e["TELEGRAM_HOME_CHANNEL"], "text": text}).encode()
    req = urllib.request.Request(f"https://api.telegram.org/bot{e['TELEGRAM_BOT_TOKEN']}/sendMessage", data=data)
    urllib.request.urlopen(req, timeout=timeout).read()


def ssh_monster(*args, timeout=120, text=True):
    """ssh monster <args> (the workstation's forced command). Returns (rc, stdout)."""
    r = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "monster", *args],
                       capture_output=True, text=text, timeout=timeout)
    return r.returncode, r.stdout
