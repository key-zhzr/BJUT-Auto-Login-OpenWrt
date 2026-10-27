"""Acceptance checker must reject partial cohorts, time drift and regressions."""
import importlib.util
from pathlib import Path
import unittest

path = Path(__file__).resolve().parents[1] / "scripts/check_traffic_cadence.py"
spec = importlib.util.spec_from_file_location("traffic_cadence", path)
cadence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cadence)


class CadenceTests(unittest.TestCase):
    def test_reads_only_expected_account_timestamps_without_error_contents(self):
        times, errors = cadence.parse_timestamps("/state/account-at 100\n/state/other-at 999\n/state/account-error private diagnostic\n", {"account"})
        self.assertEqual(times, {"account": 100})
        self.assertEqual(errors, ["account"])

    def test_accepts_six_real_accounts_with_one_second_jitter(self):
        rounds = [{str(account): 1000 + step * 60 + (account + step) % 2
                   for account in range(6)} for step in range(6)]
        summary = cadence.summarize(rounds)
        self.assertTrue(summary["passed"])
        self.assertEqual((summary["minInterval"], summary["maxInterval"]), (59, 61))

    def test_rejects_staggered_accounts_and_unstable_intervals(self):
        self.assertFalse(cadence.summarize([{"a": i * 60, "b": i * 60 + 18} for i in range(6)])["passed"])
        self.assertFalse(cadence.summarize([{"a": i * 62, "b": i * 62} for i in range(6)])["passed"])
        self.assertFalse(cadence.summarize([{"a": i * 60} for i in range(4)])["passed"])


if __name__ == "__main__":
    unittest.main()
