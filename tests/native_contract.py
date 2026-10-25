"""Read-only/negative RPC checks; never modifies application content or TCC."""
import json
import pathlib
import sys
import unittest
import urllib.request
import urllib.error

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "scripts"))
from rpc import read_endpoint


class NativeContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.config = read_endpoint()

    def rpc(self, method, params=None, authorized=True):
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.config['port']}/rpc",
            json.dumps({"method": method, "params": params or {}}).encode(),
            {"Content-Type": "application/json", "Authorization": "Bearer " + (self.config["token"] if authorized else "invalid")})
        with urllib.request.urlopen(req, timeout=10) as response:
            return json.load(response)

    def test_auth_required(self):
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.rpc("status", authorized=False)
        self.assertEqual(401, caught.exception.code)
        caught.exception.close()

    def test_status_reports_real_permissions(self):
        response = self.rpc("status")
        self.assertTrue(response["ok"])
        status = response["result"]
        self.assertEqual(1, status["protocol_version"])
        self.assertEqual("macos-ax", status["backend"])
        self.assertIsInstance(status["bundle_id"], str)
        self.assertIsInstance(status["app_name"], str)
        self.assertIsInstance(status["window_title"], str)
        self.assertIsInstance(status["node_count"], int)
        self.assertNotIn("fixture_path", status)
        if not status["active"]:
            self.assertEqual("", status["session_id"])
            self.assertEqual("", status["snapshot_id"])
            self.assertEqual("", status["bundle_id"])
        self.assertIsInstance(status["accessibility"], bool)
        self.assertIsInstance(status["screen_recording"], bool)
        self.assertTrue(pathlib.Path(status["controller_application_path"]).is_absolute())
        generic = self.rpc("computer_capabilities")["result"]
        self.assertEqual(status["controller_application_path"], generic["controller_application_path"])

    def test_unknown_method_cannot_execute(self):
        response = self.rpc("arbitrary_eval", {"code": "not executable"})
        self.assertFalse(response["ok"])
        self.assertEqual("unknown-method", response["error"]["code"])

    def test_retired_document_methods_cannot_launch_or_mutate(self):
        before = self.rpc("status")["result"]
        for method in ("start", "observe", "set_value", "move_window", "verify", "report_verification_error", "preview"):
            with self.subTest(method=method):
                response = self.rpc(method, {"value": "MUST NOT BE WRITTEN"})
                self.assertFalse(response["ok"])
                self.assertEqual("unknown-method", response["error"]["code"])
        after = self.rpc("status")["result"]
        self.assertEqual(before["controlled_window_count"], after["controlled_window_count"])

    def test_unknown_session_cannot_operate_a_window(self):
        for method in ("computer_observe", "computer_act", "computer_screenshot", "computer_detach"):
            with self.subTest(method=method):
                response = self.rpc(method, {"session_id": "nonexistent-contract-session",
                                            "action": "set_value", "value": "MUST NOT BE WRITTEN",
                                            "snapshot_id": "forged", "node_id": "forged",
                                            "request_id": "negative-contract-test"})
                self.assertFalse(response["ok"])
                self.assertEqual("session-changed", response["error"]["code"])

    def test_menu_reflects_actual_target_state(self):
        status = self.rpc("status")["result"]
        ui = self.rpc("ui_state")["result"]
        count = status["controlled_window_count"]
        self.assertEqual(str(count), ui["statusTitle"])
        self.assertEqual(count, ui["controlledWindowCount"])
        self.assertTrue(ui["statusIconVisible"])
        self.assertFalse(ui["statusThumbnailVisible"])
        if not status["active"]:
            self.assertFalse(ui["overlayVisible"])
            self.assertFalse(ui["previewLive"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
