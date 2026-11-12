"""GUI state checks; no serial connection or inference is performed."""
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import sys
import tkinter as tk
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import upload_image


class UploaderStateTests(unittest.TestCase):
    def setUp(self):
        self.root = tk.Tk()
        self.root.withdraw()
        # Clearly synthetic port; classify is never called by these tests.
        with patch.object(upload_image, "comports", return_value=[
            SimpleNamespace(device="TEST_PORT", description="Unit-test transport")
        ]):
            self.app = upload_image.Uploader(self.root)
        self.app.load_path(ROOT / "repos/SNN-FPGA/Python scripts/sample MNIST data/7.png")

    def tearDown(self):
        self.app.busy = False
        self.app.close()

    def test_failed_load_cannot_reactivate_previous_image(self):
        self.app.result.set("FPGA prediction: 7")
        with patch.object(upload_image.messagebox, "showerror"):
            self.app.load_path(ROOT / "__nonexistent_unit_test_image__.png")
        self.app.reset_crop()
        self.app.reprocess()
        self.assertIsNone(self.app.image)
        self.assertIsNone(self.app.source_path)
        self.assertIsNone(self.app.prepared)
        self.assertEqual(self.app.result.get(), "FPGA prediction: —")
        self.assertEqual(str(self.app.send_button["state"]), "disabled")

    def test_drag_clears_result_and_blocks_previous_payload(self):
        self.app.result.set("FPGA prediction: 7")
        x0, y0, x1, y1 = self.app.display_box
        self.app.start_crop(SimpleNamespace(x=x0, y=y0))
        self.assertEqual(self.app.result.get(), "FPGA prediction: —")
        self.assertEqual(str(self.app.send_button["state"]), "disabled")
        with patch.object(upload_image, "classify") as classify:
            self.app.send()
            classify.assert_not_called()
        self.app.finish_crop(SimpleNamespace(x=x1, y=y1))
        self.assertEqual(self.app.crop, (0, 0, self.app.image.width, self.app.image.height))
        self.assertEqual(len(self.app.prepared.tobytes()), 256)
        self.assertEqual(str(self.app.send_button["state"]), "normal")

    def test_transfer_failure_shows_no_prediction(self):
        self.app.set_busy(True)
        self.app.result.set("FPGA prediction: 7")
        self.app.events.put((None, "Simulated disconnected board", None, "No log in test"))
        self.root.after_cancel(self.app.poll_id)
        self.app.poll()
        self.assertFalse(self.app.busy)
        self.assertEqual(self.app.result.get(), "FPGA prediction: —")
        self.assertIn("No valid FPGA result", self.app.status.get())


if __name__ == "__main__":
    unittest.main()
