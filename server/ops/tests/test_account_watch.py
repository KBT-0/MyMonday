"""Tests for account_watch.decide (pure policy; no ssh, no Telegram)."""
import importlib, os, sys, tempfile, unittest
import unittest.mock

_tmp = tempfile.mkdtemp(prefix="account_watch_test.")
_env = os.path.join(_tmp, "local.env")
with open(_env, "w") as _f:
    # same settings as test_lead_watch: common reads local.env once per process
    _f.write('WORKSTATION_HOST=192.0.2.1\nMAC_HOST=192.0.2.2\nOPS_LANG=en\nACCOUNTS_AUTO="1 2"\nACCOUNTS_ASK="3 4"\n')
os.environ.update(MONDAY_ENV=_env, OPS_STATE=os.path.join(_tmp, "state"), HERMES_ENV=os.path.join(_tmp, "none"))
for k in ("ACCOUNTS_AUTO", "ACCOUNTS_ASK", "ACCOUNT_5H_MAX", "ACCOUNT_7D_MAX", "OPS_DIR", "WORKSTATION_HOST", "MAC_HOST", "OPS_LANG"):
    os.environ.pop(k, None)
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
aw = importlib.import_module("account_watch")


def acc(n, p5, p7, status="ok"):
    return {"number": n, "usageStatus": status, "usage": {"fiveHour": {"pct": p5}, "sevenDay": {"pct": p7}}}


def data(active, *accs):
    return {"activeAccountNumber": active, "accounts": list(accs)}


class Decide(unittest.TestCase):
    def test_fine_does_nothing(self):
        self.assertEqual(aw.decide(data(1, acc(1, 40, 50), acc(2, 0, 0)), False, {}, 1000), ("none", None))

    def test_near_limit_plans_instead_of_switching(self):
        # not urgent (below ACCOUNT_HARD): never switched here, a handoff-based switch is planned
        self.assertEqual(aw.decide(data(1, acc(1, 96, 50), acc(2, 0, 0)), False, {}, 1000), ("plan", 2))

    def test_plan_regardless_of_working_or_time(self):
        # unlike the old "wait", a non-urgent plan never turns into an immediate switch by itself
        st = {}
        self.assertEqual(aw.decide(data(1, acc(1, 96, 50), acc(2, 0, 0)), True, st, 1000), ("plan", 2))
        self.assertEqual(aw.decide(data(1, acc(1, 96, 50), acc(2, 0, 0)), True, st, 1000 + 21 * 60), ("plan", 2))

    def test_hard_limit_switches_mid_turn(self):
        self.assertEqual(aw.decide(data(1, acc(1, 99.5, 50), acc(2, 0, 0)), True, {}, 1000), ("switch", 2))

    def test_never_switches_to_ask_accounts(self):
        d = data(1, acc(1, 50, 98), acc(2, 10, 97.5), acc(3, 0, 0, "relogin_required"), acc(4, 0, 84))
        self.assertEqual(aw.decide(d, False, {}, 1000), ("ask", [4]))

    def test_stuck_when_nothing_left(self):
        d = data(2, acc(1, 50, 98), acc(2, 97, 10), acc(4, 0, 99))
        self.assertEqual(aw.decide(d, False, {}, 1000), ("stuck", None))

    def test_broken_login_counts_as_spent(self):
        self.assertEqual(aw.decide(data(1, acc(1, 0, 0, "relogin_required"), acc(2, 0, 0)), True, {}, 1000),
                         ("switch", 2))

    def test_recovery_clears_episode(self):
        st = {"near_since": 1, "asked": 2, "planned": 3}
        aw.decide(data(4, acc(4, 10, 10)), False, st, 1000)
        self.assertEqual(st, {})


class Run(unittest.TestCase):
    """run(): the NEEDED file is how the non-urgent case hands off to the monitored Hermes job."""

    def setUp(self):
        for f in (aw.STATE, aw.NEEDED, aw.LOCK):
            try:
                os.remove(f)
            except OSError:
                pass

    def run_once(self, data_, lst="alpha active kit yes idle 1h\n", send=None):
        def fake_ssh(*args, timeout=15):
            if args[:2] == ("lead", "accounts"):
                import json as _j
                return 0, _j.dumps(data_)
            if args[:2] == ("lead", "list"):
                return 0, lst
            if args[:2] == ("lead", "account-switch"):
                return 0, "ok"
            return 1, ""
        sent = []
        with unittest.mock.patch.object(aw, "ssh_workstation", fake_ssh), \
                unittest.mock.patch.object(aw, "notify", send or sent.append):
            aw.main()
        return sent

    def test_plan_writes_needed_file_once(self):
        d = data(1, acc(1, 96, 50), acc(2, 0, 0))
        sent = self.run_once(d)
        self.assertTrue(os.path.exists(aw.NEEDED))
        self.assertEqual(len(sent), 1)  # one notice per episode, not every 2 minutes
        sent2 = self.run_once(d)
        self.assertEqual(sent2, [])

    def test_recovered_quota_clears_stale_needed_file(self):
        self.run_once(data(1, acc(1, 96, 50), acc(2, 0, 0)))
        self.assertTrue(os.path.exists(aw.NEEDED))
        self.run_once(data(1, acc(1, 10, 10), acc(2, 0, 0)))
        self.assertFalse(os.path.exists(aw.NEEDED))

    def test_urgent_switches_and_clears_needed_file(self):
        self.run_once(data(1, acc(1, 96, 50), acc(2, 0, 0)))  # plans first
        self.assertTrue(os.path.exists(aw.NEEDED))
        self.run_once(data(1, acc(1, 99.9, 50), acc(2, 0, 0)))  # now urgent: switches at once
        self.assertFalse(os.path.exists(aw.NEEDED))


class Protect(unittest.TestCase):
    """ACCOUNT_PROTECT: cap lower, and never switch back once reserved (the owner's rule for his own account)."""

    def test_protected_account_capped_lower_and_reserved(self):
        old_protect, old_max = aw.PROTECT, aw.PROTECT_MAX
        aw.PROTECT, aw.PROTECT_MAX = {1}, 95
        try:
            st = {}
            # below the generic 97% 7d cap but over the protected 95% cap: still leaves it
            action, x = aw.decide(data(1, acc(1, 10, 96), acc(2, 0, 0)), False, st, 1000)
            self.assertEqual((action, x), ("plan", 2))
            self.assertEqual(st["reserved"], [1])
        finally:
            aw.PROTECT, aw.PROTECT_MAX = old_protect, old_max

    def test_reserved_account_never_chosen_again(self):
        old_protect, old_max = aw.PROTECT, aw.PROTECT_MAX
        aw.PROTECT, aw.PROTECT_MAX = {1}, 95
        try:
            st = {"reserved": [1]}
            # account 1 looks fresh again (e.g. after a weekly reset) but must stay excluded
            action, x = aw.decide(data(2, acc(1, 0, 0), acc(2, 96, 10)), False, st, 1000)
            self.assertEqual((action, x), ("stuck", None))
        finally:
            aw.PROTECT, aw.PROTECT_MAX = old_protect, old_max

    def test_reservation_survives_recovery_of_other_fields(self):
        old_protect, old_max = aw.PROTECT, aw.PROTECT_MAX
        aw.PROTECT, aw.PROTECT_MAX = {1}, 95
        try:
            st = {"near_since": 1, "asked": 2, "reserved": [1]}
            aw.decide(data(4, acc(4, 10, 10), acc(1, 0, 0)), False, st, 1000)
            self.assertEqual(st.get("reserved"), [1])  # cleared episode fields, kept the reservation
        finally:
            aw.PROTECT, aw.PROTECT_MAX = old_protect, old_max


if __name__ == "__main__":
    unittest.main()
