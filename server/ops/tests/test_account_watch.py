"""Tests for account_watch.decide (pure policy; no ssh, no Telegram)."""
import importlib, os, sys, tempfile, unittest

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

    def test_switch_at_turn_boundary(self):
        self.assertEqual(aw.decide(data(1, acc(1, 96, 50), acc(2, 0, 0)), False, {}, 1000), ("switch", 2))

    def test_wait_while_working_then_switch(self):
        st = {}
        self.assertEqual(aw.decide(data(1, acc(1, 96, 50), acc(2, 0, 0)), True, st, 1000)[0], "wait")
        self.assertEqual(aw.decide(data(1, acc(1, 96, 50), acc(2, 0, 0)), True, st, 1000 + 21 * 60)[0], "switch")

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
        st = {"near_since": 1, "asked": 2}
        aw.decide(data(4, acc(4, 10, 10)), False, st, 1000)
        self.assertEqual(st, {})


if __name__ == "__main__":
    unittest.main()
