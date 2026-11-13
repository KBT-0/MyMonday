"""Unit tests of server/ops/lead_watch.py: pure functions and one run of main() with ssh, Tailscale and
Telegram mocked. Nothing leaves the machine; state goes to a temp dir.
Run from the repo root:  python3 -m unittest discover -s server/ops/tests -v
"""
import atexit, importlib, json, os, shutil, sys, tempfile, time, unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
OPS = os.path.dirname(HERE)
_tmp = tempfile.mkdtemp(prefix="lead_watch_test.")
atexit.register(shutil.rmtree, _tmp, True)
_env = os.path.join(_tmp, "local.env")
with open(_env, "w") as _f:
    _f.write("MONSTER_HOST=192.0.2.1\nMAC_HOST=192.0.2.2\nOPS_LANG=en\n")
os.environ.update(MONDAY_ENV=_env, OPS_STATE=os.path.join(_tmp, "state"), HERMES_ENV=os.path.join(_tmp, "none"))
for k in ("MONSTER_HOST", "MAC_HOST", "OPS_LANG", "OPS_DIR"):
    os.environ.pop(k, None)
sys.path.insert(0, OPS)
lw = importlib.import_module("lead_watch")
os.makedirs(lw.S, exist_ok=True)

NOW = 1_800_000_000.0
LIST = "alpha active kit yes waiting_question 20m\nbeta active manual yes idle 2m\ngamma parked kit dead - -\n"


def rd(path):
    with open(path) as f:
        return f.read()


def wr(path, text):
    with open(path, "w") as f:
        f.write(text)


def state():
    return json.loads(rd(lw.STATE))


def ev(lead, event, ts, **kw):
    return json.dumps({"ts": ts, "lead": lead, "event": event, **kw})


class Pure(unittest.TestCase):
    def test_parse_list(self):
        s = lw.parse_list(LIST)
        self.assertEqual(set(s), {"alpha", "beta", "gamma"})
        self.assertEqual(s["alpha"], {"state": "active", "run": "yes", "last": "waiting_question", "age": 1200})
        self.assertIsNone(s["gamma"]["last"])
        self.assertIsNone(s["gamma"]["age"])

    def test_parse_events(self):
        out = ev("a", "stop", NOW) + "\nnot json\n[1]\nOFFSET 512\n"
        events, off = lw.parse_events(out, 10)
        self.assertEqual(len(events), 1)
        self.assertEqual(off, 512)
        self.assertEqual(lw.parse_events("", 7), ([], 7))

    def test_classify_mode1(self):
        events = [json.loads(ev("a", "question", NOW - 60)), json.loads(ev("b", "stop", NOW - 30)),
                  json.loads(ev("b", "prompt", NOW - 10)), json.loads(ev("c", "stop", NOW - 5, bg=True)),
                  json.loads(ev("x", "failure", NOW)), json.loads(ev("d", "stop", NOW - 3600))]
        delayed = {}
        p = lw.classify(events, {"a", "b", "c", "d"}, set(), lw.MODES["full"], False, NOW, delayed)
        self.assertEqual(set(p), {"a"})  # b cancelled, c background, x unregistered, d too old
        self.assertEqual(delayed, {})

    def test_classify_mode2_holds_stops(self):
        events = [json.loads(ev("a", "stop", NOW - 60)), json.loads(ev("b", "question", NOW - 60)),
                  json.loads(ev("c", "failure", NOW - 60))]
        delayed = {}
        p = lw.classify(events, {"a", "b", "c"}, set(), lw.MODES["escalation"], True, NOW, delayed)
        self.assertEqual(set(p), {"c"})
        self.assertEqual(set(delayed), {"a"})

    def test_mute(self):
        events = [json.loads(ev("a", "failure", NOW))]
        self.assertEqual(lw.classify(events, {"a"}, {"a"}, lw.MODES["full"], False, NOW, {}), {})
        self.assertEqual(lw.classify(events, {"a"}, {"all"}, lw.MODES["full"], False, NOW, {}), {})

    def test_mode2_waits_busy_filter_only_for_stops(self):
        since = NOW - 3 * 3600
        st = {"remind": {"q": {"since": NOW - 40 * 60}}, "delayed": {
            "s_idle": {"ts": NOW - 40 * 60}, "s_busy": {"ts": NOW - 40 * 60}, "s_new": {"ts": NOW - 10 * 60}}}
        busy = mock.Mock(side_effect=lambda n: n in ("q", "s_busy"))
        self.assertEqual(lw.mode2_waits(st, NOW, since, busy), ["q", "s_idle"])
        self.assertNotIn(mock.call("q"), busy.call_args_list)  # a question never needs a screen read

    def test_mode2_waits_only_after_mode2_start(self):
        since = NOW - 20 * 60  # mode 2 began 20 min ago
        st = {"remind": {"q": {"since": NOW - 3 * 3600}}, "delayed": {"s": {"ts": NOW - 3 * 3600}}}
        self.assertEqual(lw.mode2_waits(st, NOW, since, lambda n: False), [])

    def test_mode2_since_drops_stale_delayed(self):
        wm = lw.WORK_MODE_FILE
        os.makedirs(os.path.dirname(wm), exist_ok=True)
        wr(wm, "2\n")
        os.utime(wm, (NOW, NOW))
        st = {"delayed": {"old": {"ts": NOW - 5 * 3600}, "new": {"ts": NOW + 5}}}
        self.assertEqual(lw.mode2_since(st), NOW)
        self.assertEqual(set(st["delayed"]), {"new"})
        os.remove(wm)

    def test_remind_uses_list_age(self):
        st = lw.load()
        st["outbox"] = []
        states = lw.parse_list(LIST)
        lw.remind(st, states, set(), NOW)
        self.assertEqual(st["remind"]["alpha"]["since"], NOW - 1200)
        self.assertEqual(len(st["outbox"]), 1)  # 20 min waited -> first reminder
        lw.remind(st, states, set(), NOW + 60)
        self.assertEqual(len(st["outbox"]), 1)  # not again before 30 min
        lw.remind(st, lw.parse_list("alpha active kit yes working 1m\n"), set(), NOW + 120)
        self.assertNotIn("alpha", st["remind"])

    def test_crashed_once(self):
        st = lw.load()
        st["outbox"], st["crashed"] = [], {}
        dead = lw.parse_list("a active kit dead working 5m\nb active kit dead ended 5m\nc parked kit dead idle 1h\n")
        lw.crashed(st, dead, set(), NOW)
        lw.crashed(st, dead, set(), NOW + 60)
        self.assertEqual(len(st["outbox"]), 1)
        self.assertIn("[a]", st["outbox"][0]["text"])
        lw.crashed(st, lw.parse_list("a active kit yes working 1m\n"), set(), NOW + 120)
        self.assertEqual(st["crashed"], {})

    def test_flush_keeps_failed(self):
        st = lw.load()
        st["outbox"] = [{"ts": time.time(), "text": "one"}, {"ts": time.time(), "text": "two"}]
        sent = []

        def flaky(text):
            if text == "two":
                raise OSError("telegram down")
            sent.append(text)
        lw.flush(st, flaky)
        self.assertEqual(sent, ["one"])
        self.assertEqual([m["text"] for m in st["outbox"]], ["two"])
        st["outbox"].append({"ts": time.time() - lw.OUTBOX_MAX_AGE - 1, "text": "stale"})
        lw.flush(st, sent.append)
        self.assertEqual(sent, ["one", "two"])
        self.assertEqual(st["outbox"], [])


class Main(unittest.TestCase):
    def setUp(self):
        for f in (lw.STATE, lw.WORK_MODE_FILE):
            if os.path.exists(f):
                os.remove(f)
        lw._peers = []
        lw._T0 = time.monotonic()

    def run_main(self, events, lst, send=None, rc=0):
        calls = []

        def fake_ssh(*args, timeout=15):
            calls.append(args)
            if rc:
                return rc, ""
            if args[:2] == ("lead", "events"):
                return 0, events
            if args[:2] == ("lead", "list"):
                return 0, lst
            if args[0] == "read":
                return 0, "❯ "
            return 1, ""
        sent = []
        with mock.patch.object(lw, "ssh", fake_ssh), \
                mock.patch.object(lw, "send", send or sent.append):
            lw.main()
        return calls, sent

    def test_send_failure_keeps_notice_and_offset(self):
        now = time.time()
        out = ev("beta", "failure", now - 5) + "\nOFFSET 100\n"

        def down(text):
            raise OSError("down")
        calls, _ = self.run_main(out, LIST, send=down)
        st = state()
        self.assertEqual(st["offset"], 100)
        self.assertEqual(len(st["outbox"]), 2)  # failure now + reminder for alpha (20 min)
        self.assertNotIn(("lead", "status", "--json"), calls)
        calls, sent = self.run_main("OFFSET 100\n", LIST)
        self.assertIn("[beta]", sent[0])
        self.assertEqual(state()["outbox"], [])
        self.assertIn(("lead", "events", "100"), calls)

    def test_monster_off_is_silent(self):
        calls, sent = self.run_main("", "", rc=255)
        self.assertEqual(sent, [])
        self.assertEqual(state()["fails"], 0)

    def test_ssh_broken_while_online(self):
        lw._peers = [{"TailscaleIPs": ["192.0.2.1"], "Online": True}]
        self.run_main("", "", rc=255)
        st = state()
        st["unreach_since"] -= lw.UNREACH + 1
        wr(lw.STATE, json.dumps(st))
        lw._peers = [{"TailscaleIPs": ["192.0.2.1"], "Online": True}]
        _, sent = self.run_main("", "", rc=255)
        self.assertEqual(len(sent), 1)
        lw._peers = [{"TailscaleIPs": ["192.0.2.1"], "Online": True}]
        _, sent = self.run_main("", "", rc=255)
        self.assertEqual(sent, [])  # once

    def test_mode2_exit_on_question(self):
        now = time.time()
        wr(lw.WORK_MODE_FILE, "2\n")
        os.utime(lw.WORK_MODE_FILE, (now - 3600, now - 3600))
        lst = "alpha active kit yes waiting_question 40m\n"
        calls, sent = self.run_main("OFFSET 0\n", lst)
        self.assertEqual(rd(lw.WORK_MODE_FILE).strip(), "1")
        self.assertTrue(any("alpha" in s and "mode 1" in s for s in sent))
        self.assertFalse([c for c in calls if c[0] == "read"])  # no screen read for a question

    def test_mode2_stays_for_old_question(self):
        now = time.time()
        wr(lw.WORK_MODE_FILE, "2\n")
        os.utime(lw.WORK_MODE_FILE, (now - 600, now - 600))  # mode 2 began 10 min ago
        self.run_main("OFFSET 0\n", "alpha active kit yes waiting_question 3h\n")
        self.assertEqual(rd(lw.WORK_MODE_FILE).strip(), "2")


if __name__ == "__main__":
    unittest.main()
