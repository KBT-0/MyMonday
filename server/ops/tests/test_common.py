"""Unit tests of server/ops/common.py: config lookup with the pre-rename key names (MONSTER_*, read for
one release when the WORKSTATION_* key is unset) and the workstation's ssh alias.
Run from the repo root:  python3 -m unittest discover -s server/ops/tests -v
"""
import os, subprocess, sys, unittest
from unittest import mock

OPS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, OPS)


def _common():
    # imported on first use, not at collection: test_lead_watch points MONDAY_ENV at its own config
    # before it imports lead_watch (and so common); the cases here patch CONF themselves
    import common
    return common


class Conf(unittest.TestCase):
    def conf(self, d, *a):
        with mock.patch.dict(_common().CONF, d, clear=True):
            return _common().conf(*a)

    def test_new_key(self):
        self.assertEqual(self.conf({"WORKSTATION_HOST": "192.0.2.1"}, "WORKSTATION_HOST"), "192.0.2.1")

    def test_legacy_key_is_fallback(self):
        self.assertEqual(self.conf({"MONSTER_HOST": "192.0.2.9"}, "WORKSTATION_HOST"), "192.0.2.9")

    def test_new_key_wins(self):
        d = {"WORKSTATION_HOST": "192.0.2.1", "MONSTER_HOST": "192.0.2.9"}
        self.assertEqual(self.conf(d, "WORKSTATION_HOST"), "192.0.2.1")

    def test_empty_new_key_falls_back(self):
        d = {"WORKSTATION_HOST": "", "MONSTER_HOST": "192.0.2.9"}
        self.assertEqual(self.conf(d, "WORKSTATION_HOST"), "192.0.2.9")

    def test_default(self):
        self.assertEqual(self.conf({}, "WORKSTATION_HOST", "x"), "x")

    def test_other_keys_untouched(self):
        self.assertEqual(self.conf({"MONSTER_HOST": "192.0.2.9"}, "MAC_HOST"), "")


class Alias(unittest.TestCase):
    def alias(self, d):
        with mock.patch.dict(_common().CONF, d, clear=True):
            return _common().workstation_alias()

    def test_default(self):
        self.assertEqual(self.alias({}), "workstation")

    def test_set(self):
        self.assertEqual(self.alias({"WORKSTATION_SSH_ALIAS": "ws", "WORKSTATION_HOST": "192.0.2.1"}), "ws")

    def test_legacy_config_keeps_old_alias(self):
        self.assertEqual(self.alias({"MONSTER_HOST": "192.0.2.9"}), "monster")

    def test_new_config_default(self):
        self.assertEqual(self.alias({"WORKSTATION_HOST": "192.0.2.1"}), "workstation")

    def test_ssh_uses_alias(self):
        r = subprocess.CompletedProcess([], 0, "ok", "")
        with mock.patch.dict(_common().CONF, {"WORKSTATION_SSH_ALIAS": "ws"}, clear=True), \
                mock.patch.object(_common().subprocess, "run", return_value=r) as run:
            self.assertEqual(_common().ssh_workstation("status"), (0, "ok"))
        self.assertEqual(run.call_args[0][0][-2:], ["ws", "status"])


if __name__ == "__main__":
    unittest.main()
