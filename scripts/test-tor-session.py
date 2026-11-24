#!/usr/bin/env python3
"""Regression checks for Tor setup and VPN launch gates."""
import importlib.util
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


class TorLaunchTests(unittest.TestCase):
    def setUp(self):
        path = Path(__file__).resolve().parents[1] / "bin/tor-session.py"
        spec = importlib.util.spec_from_file_location("tor_session", path)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        self.module.SUPPORT_DIR = root
        self.module.MODE_PREF = root / "mode"
        self.module.SETUP_PREF = root / "setup"
        self.module.WG_CONF = root / "wg.conf"
        self.module.DESK = root / "desk"
        self.module.DESK.touch()
        self.module.DESK.chmod(0o700)
        self.module.APPLIANCE_MANIFEST = root / "manifest"
        self.module.SESSION_STATUS = root / "session.json"
        self.real_running_session = self.module.running_session
        for name in ("open_setup", "feedback", "focus_existing", "running_session"):
            replacement = patch.object(self.module, name)
            mock = replacement.start()
            self.addCleanup(replacement.stop)
            setattr(self, name, mock)
        self.running_session.return_value = None
        self.focus_existing.return_value = False
        self.run_patch = patch.object(self.module.subprocess, "run")
        self.run = self.run_patch.start()
        self.addCleanup(self.run_patch.stop)

    def test_status_ignores_a_pid_running_another_program(self):
        self.module.SESSION_STATUS.write_text('{"pid": 123, "mode": "wireguard", "phase": "connected"}')
        self.run.side_effect = [
            SimpleNamespace(stdout="/usr/bin/unrelated\n"),
            SimpleNamespace(stdout=""),
        ]
        self.assertIsNone(self.real_running_session())

    def test_status_recognizes_the_mac_app_executable(self):
        self.module.SESSION_STATUS.write_text('{"pid": 123, "mode": "wireguard", "phase": "blocked"}')
        executable = self.module.DESK.parent / ".build/TorRoom.app/Contents/MacOS/tor-room"
        self.run.return_value = SimpleNamespace(stdout=str(executable) + "\n")
        self.assertEqual(self.real_running_session()["phase"], "blocked")

    def test_first_launch_opens_setup_without_starting_guest(self):
        self.assertEqual(self.module.current_mode(), "wireguard")
        self.module.launch()
        self.open_setup.assert_called_once()
        self.run.assert_not_called()

    def test_explicit_vpn_with_missing_config_stays_blocked(self):
        self.module.save_mode("wireguard")
        status = self.module.status_dict()
        self.assertEqual(status["mode"], "wireguard")
        self.assertFalse(status["hasWireguard"])
        self.module.launch()
        self.open_setup.assert_called_once()
        self.run.assert_not_called()

    def test_tor_only_requires_confirmation_on_each_launch(self):
        self.module.save_mode("tor-only")
        with patch.object(self.module, "confirm_tor_only", side_effect=[False, True]) as confirm:
            self.module.launch()
            self.run.assert_not_called()
            self.module.launch()
            self.run.assert_called_once_with([str(self.module.DESK), "tor"], check=True)
            self.assertEqual(confirm.call_count, 2)

    def test_running_tor_only_session_warns_even_if_vpn_selected(self):
        self.module.save_mode("wireguard")
        self.running_session.return_value = {"mode": "tor-only", "phase": "tor-only"}
        with patch.object(self.module, "confirm_tor_only", return_value=False):
            self.module.launch()
        self.focus_existing.assert_not_called()
        self.run.assert_not_called()

    def test_dialog_cancel_and_failure_never_approve(self):
        for result in (
            SimpleNamespace(returncode=1, stdout=""),
            SimpleNamespace(returncode=0, stdout="Cancel\n"),
            SimpleNamespace(returncode=0, stdout="Unexpected\n"),
        ):
            with self.subTest(result=result):
                self.run.return_value = result
                self.assertFalse(self.module.confirm_tor_only())

    def test_dialog_configure_routes_to_setup(self):
        self.run.return_value = SimpleNamespace(returncode=0, stdout="Configure VPN\n")
        self.assertFalse(self.module.confirm_tor_only())
        self.open_setup.assert_called_once()

    def test_unknown_saved_mode_does_not_choose_direct(self):
        self.module.MODE_PREF.write_text("corrupt")
        with self.assertRaises(ValueError):
            self.module.current_mode()


if __name__ == "__main__":
    unittest.main()
