"""Read-only/negative RPC checks; never writes TextEdit content or changes TCC."""
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
        self.assertEqual("com.apple.TextEdit", status["bundle_id"])
        self.assertIsInstance(status["accessibility"], bool)
        self.assertIsInstance(status["screen_recording"], bool)

    def test_unknown_method_cannot_execute(self):
        response = self.rpc("arbitrary_eval", {"code": "not executable"})
        self.assertFalse(response["ok"])
        self.assertEqual("unknown-method", response["error"]["code"])

    def test_missing_action_identity_rejected(self):
        response = self.rpc("set_value", {"value": "MUST NOT BE WRITTEN"})
        self.assertFalse(response["ok"])
        self.assertEqual("invalid-request", response["error"]["code"])

    def test_forged_snapshot_rejected(self):
        response = self.rpc("set_value", {"request_id": "negative-test-forged-snapshot", "snapshot_id": "not-a-real-snapshot", "node_id": "n0", "value": "MUST NOT BE WRITTEN"})
        self.assertFalse(response["ok"])
        self.assertEqual("stale-target", response["error"]["code"])

    def test_cannot_claim_unperformed_verification(self):
        response = self.rpc("verify", {"success": True, "request_id": "nonexistent", "expected_value": "fake"})
        self.assertFalse(response["ok"])
        self.assertEqual("invalid-verification", response["error"]["code"])

    def test_move_requires_current_snapshot(self):
        response = self.rpc("move_window", {"request_id": "negative-test-forged-move", "snapshot_id": "not-a-real-snapshot", "x": 100, "y": 100})
        self.assertFalse(response["ok"])
        self.assertEqual("stale-target", response["error"]["code"])

    def test_error_report_requires_real_action(self):
        response = self.rpc("report_verification_error", {"request_id": "nonexistent", "stage": "native-verification", "message": "fake"})
        self.assertFalse(response["ok"])
        self.assertEqual("invalid-verification", response["error"]["code"])

    def test_menu_reflects_actual_target_state(self):
        status = self.rpc("status")["result"]
        ui = self.rpc("ui_state")["result"]
        self.assertIn("TextEdit", ui["statusTitle"])
        if not status["active"]:
            self.assertIn("空闲", ui["statusTitle"])
            self.assertFalse(ui["overlayVisible"])
            self.assertFalse(ui["previewLive"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
