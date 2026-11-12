"""Check the ten bundled examples using a connected FPGA, never CPU inference.

Run only after programming the board: python hardware_smoke.py --port COM5
The selected examples are a hardware acceptance check, not an accuracy estimate.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / "reports" / "hardware_smoke.json"
sys.path.insert(0, str(ROOT / "host"))


def timestamp():
    return datetime.now(timezone.utc).isoformat()


def save_report(report):
    """Replace the report after every step, including before the first transfer."""
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    temporary = REPORT.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    temporary.replace(REPORT)


def sample_cases():
    manifest = json.loads((ROOT / "data" / "samples_manifest.json").read_text(encoding="utf-8"))
    entries = manifest["samples"]
    by_name = {entry["png"]: entry for entry in entries}
    images = sorted((ROOT / "data" / "samples").glob("*.png"))
    if len(images) != 10 or len(entries) != 10 or len(by_name) != 10:
        raise ValueError("Expected exactly ten PNGs and ten distinct sample manifest entries.")
    cases = []
    for image in images:
        name = image.relative_to(ROOT / "data").as_posix()
        match = re.fullmatch(r"digit_([0-9])_index_([0-9]+)\.png", image.name)
        if not match or name not in by_name:
            raise ValueError(f"Unexpected or unlisted sample: {image.name}")
        expected, test_index = map(int, match.groups())
        entry = by_name[name]
        if (entry["label"] != expected or entry["reference_prediction"] != expected
                or entry["test_index"] != test_index):
            raise ValueError(f"Filename and manifest disagree: {image.name}")
        cases.append((image, expected, test_index, entry["raw_sha256"]))
    if sorted(case[1] for case in cases) != list(range(10)):
        raise ValueError("Samples must include exactly one example of every digit 0 through 9.")
    return cases


def update_totals(report):
    samples = report["samples"]
    report["attempted_samples"] = len(samples)
    report["valid_serial_responses"] = sum(item["response_received"] for item in samples)
    report["matching_predictions"] = sum(item["matches_expected"] for item in samples)
    report["physical_hardware_test"] = report["valid_serial_responses"] > 0
    report["hardware_validation_complete"] = report["valid_serial_responses"] == 10


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True, help="Explicit COM port for the programmed Basys 3; never guessed")
    args = parser.parse_args()
    report = {
        "purpose": "Ten selected demonstration samples: hardware acceptance, not an accuracy estimate",
        "started_utc": timestamp(),
        "finished_utc": None,
        "port": args.port,
        "result": "IN_PROGRESS",
        "passed": False,
        "physical_hardware_test": False,
        "hardware_validation_complete": False,
        "expected_samples": 10,
        "attempted_samples": 0,
        "valid_serial_responses": 0,
        "matching_predictions": 0,
        "display_visually_verified": False,
        "samples": [],
    }
    # Invalidate an earlier PASS before imports, input checks, or serial access.
    save_report(report)
    try:
        if not args.port.strip():
            raise ValueError("--port must name a real serial port.")
        from uploader import prepare_image, send_and_record

        cases = sample_cases()
        for image_path, expected, test_index, expected_hash in cases:
            sample = {
                "image": image_path.relative_to(ROOT).as_posix(),
                "test_index": test_index,
                "expected_digit": expected,
                "response_received": False,
                "matches_expected": False,
                "status": "IN_PROGRESS",
            }
            report["samples"].append(sample)
            update_totals(report)
            save_report(report)
            try:
                image = prepare_image(image_path, preserve=True)
                payload_hash = hashlib.sha256(image.tobytes()).hexdigest()
                if payload_hash != expected_hash:
                    raise ValueError("Prepared PNG pixels do not match the sample manifest checksum.")
                # This is the same real serial path used by the GUI; no mocks,
                # model imports, inferred predictions, or simulation fallback.
                response = send_and_record(args.port, image_path, image)
                sample["response"] = response
                sample["response_received"] = True
                sample["matches_expected"] = response["digit"] == expected
                sample["status"] = "PASS" if sample["matches_expected"] else "MISMATCH"
                if not sample["matches_expected"]:
                    sample["error"] = f"Expected {expected}; FPGA returned {response['digit']}."
            except Exception as error:
                sample["status"] = "ERROR"
                sample["error"] = f"{type(error).__name__}: {error}"
            update_totals(report)
            save_report(report)
            print(f"{image_path.name}: {sample['status']}", flush=True)
        report["passed"] = (report["hardware_validation_complete"]
                            and report["matching_predictions"] == 10)
        report["result"] = "PASS" if report["passed"] else "FAIL"
    except (Exception, KeyboardInterrupt) as error:
        report["result"] = "ERROR"
        report["error"] = f"{type(error).__name__}: {error}"
        for sample in report["samples"]:
            if sample["status"] == "IN_PROGRESS":
                sample["status"] = "INTERRUPTED"
                sample["error"] = report["error"]
    finally:
        update_totals(report)
        report["finished_utc"] = timestamp()
        save_report(report)
    print(json.dumps(report, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
