"""Verification only: integer model of the FPGA's committed pretrained MLP.

The runtime UART uploader must not import this module or compute predictions.
This file exists to test the FPGA arithmetic and measure model accuracy offline.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image

PROJECT = Path(__file__).resolve().parents[1]
DEFAULT_WEIGHTS = PROJECT.parent / "repos" / "neural-net-on-fpga" / "hdl" / "weights"
OFFICIAL_KERAS_SHA256 = "731c5ac602752760c8e48fbffcf8c3b850d9dc2a2aedcf2cc48468fc17b673d1"
SHIFT1 = 10


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_signed_mem(path: Path, bits: int, count: int) -> np.ndarray:
    values = []
    for line in path.read_text(encoding="ascii").splitlines():
        token = line.split("//", 1)[0].strip()
        if token:
            value = int(token, 16)
            if not 0 <= value < 1 << bits:
                raise ValueError(f"Value outside {bits}-bit range in {path}")
            values.append(value - (1 << bits) if value & (1 << (bits - 1)) else value)
    if len(values) != count:
        raise ValueError(f"{path}: expected {count} values, got {len(values)}")
    return np.array(values, dtype=np.int64)


def load_weights(directory: Path) -> dict[str, np.ndarray]:
    weights = {
        "w1": read_signed_mem(directory / "fc1_weights.mem", 8, 32 * 784).reshape(32, 784),
        "b1": read_signed_mem(directory / "fc1_bias.mem", 32, 32),
        "w2": read_signed_mem(directory / "fc2_weights.mem", 8, 10 * 32).reshape(10, 32),
        "b2": read_signed_mem(directory / "fc2_bias.mem", 32, 10),
    }
    # Prove that every partial MAC sum fits signed int32 for ANY uint8 input,
    # not just these examples. This permits exact int64 reference arithmetic.
    for layer in (1, 2):
        bounds = np.abs(weights[f"b{layer}"]) + 255 * np.abs(weights[f"w{layer}"]).sum(axis=1)
        if np.any(bounds > np.iinfo(np.int32).max):
            raise ValueError(f"Layer {layer} could overflow int32; reference requires wrap emulation")
    return weights


def infer(images: np.ndarray, weights: dict[str, np.ndarray]) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    if images.dtype != np.uint8 or images.shape[-2:] != (28, 28):
        raise ValueError("Expected uint8 images shaped [N,28,28]")
    pixels = images.reshape(-1, 784).astype(np.int64)
    acc1 = pixels @ weights["w1"].T + weights["b1"]
    hidden = np.clip(acc1 >> SHIFT1, 0, 255)
    logits = hidden @ weights["w2"].T + weights["b2"]
    # np.argmax returns the first maximum, matching the RTL's strict > update.
    predictions = logits.argmax(axis=1).astype(np.uint8)
    return predictions, hidden.astype(np.uint8), logits.astype(np.int32)


def write_mem(path: Path, values: np.ndarray, bits: int) -> None:
    mask = (1 << bits) - 1
    width = (bits + 3) // 4
    path.write_text("".join(f"{int(value) & mask:0{width}x}\n" for value in values.flat), encoding="ascii")


def json_write(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def load_dataset(source: Path, destination: Path) -> tuple[np.ndarray, np.ndarray]:
    if not source.exists():
        raise FileNotFoundError(f"Offline MNIST archive not found: {source}")
    with np.load(source, allow_pickle=False) as archive:
        images = archive["x_test"]
        labels = archive["y_test"]
    if images.shape != (10000, 28, 28) or labels.shape != (10000,):
        raise ValueError("Expected the full 10,000-image MNIST test split")
    if images.dtype != np.uint8 or labels.dtype != np.uint8 or np.any(labels > 9):
        raise ValueError("Unexpected MNIST data type or label range")
    if source.resolve() != destination.resolve():
        source_hash = sha256(source)
        if source.name == "mnist.npz" and source_hash != OFFICIAL_KERAS_SHA256:
            raise ValueError("Cached Keras MNIST archive does not match its published SHA256")
        np.savez_compressed(destination, x_test=images, y_test=labels)
        json_write(destination.with_name("dataset_manifest.json"), {
            "dataset": "MNIST original test split",
            "images": 10000,
            "shape": [10000, 28, 28],
            "pixel_format": "uint8 grayscale, bright digit on dark background, original order",
            "source_cache": str(source),
            "source_url": "https://storage.googleapis.com/tensorflow/tf-keras-datasets/mnist.npz",
            "source_sha256": source_hash,
            "matches_official_keras_sha256": source_hash == OFFICIAL_KERAS_SHA256,
            "stored_file": destination.name,
            "stored_sha256": sha256(destination),
            "copyright": "MNIST by Yann LeCun and Corinna Cortes; derived from NIST",
            "license_as_documented_by_keras": "CC BY-SA 3.0",
            "license_url": "https://creativecommons.org/licenses/by-sa/3.0/",
            "preprocessing": "None. Original pixels and labels copied; training split excluded.",
        })
    return images, labels


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--weights", type=Path, default=DEFAULT_WEIGHTS)
    parser.add_argument("--source", type=Path, default=PROJECT / "data" / "mnist_test.npz")
    args = parser.parse_args()
    data_dir = PROJECT / "data"
    verification_dir = PROJECT / "verification"
    data_dir.mkdir(parents=True, exist_ok=True)
    verification_dir.mkdir(parents=True, exist_ok=True)
    images, labels = load_dataset(args.source, data_dir / "mnist_test.npz")
    weights = load_weights(args.weights)
    predictions, hidden, logits = infer(images, weights)
    correct = predictions == labels
    confusion = np.zeros((10, 10), dtype=np.int64)
    np.add.at(confusion, (labels, predictions), 1)
    error_indices = np.flatnonzero(~correct)
    report = {
        "purpose": "Offline verification/reference only; not used by runtime UART uploader",
        "evaluation": "Python integer arithmetic matching the committed FPGA inference equations",
        "not_measured": "Physical FPGA classification accuracy or timing",
        "upstream_repository": "https://github.com/ZakriyaParacha46/neural-net-on-fpga",
        "network": [784, 32, 10],
        "input": "Original 28x28 uint8 MNIST grayscale pixels, no normalization or threshold",
        "arithmetic": "int8 weights; int32 biases/MAC; hidden=clamp(acc1>>10,0,255); argmax(logits)",
        "shift1": SHIFT1,
        "sample_count": int(labels.size),
        "correct": int(correct.sum()),
        "errors": int((~correct).sum()),
        "accuracy_percent": float(correct.mean() * 100),
        "confusion_matrix_rows_true_columns_predicted": confusion.tolist(),
        "per_digit": [
            {"digit": digit, "count": int(confusion[digit].sum()),
             "correct": int(confusion[digit, digit]),
             "accuracy_percent": float(100 * confusion[digit, digit] / confusion[digit].sum())}
            for digit in range(10)
        ],
        "error_indices": error_indices.tolist(),
        "all_test_predictions": predictions.tolist(),
        "parameter_sha256": {name: sha256(args.weights / name) for name in (
            "fc1_weights.mem", "fc1_bias.mem", "fc2_weights.mem", "fc2_bias.mem", "parameters.vh")},
        "test_archive_sha256": sha256(data_dir / "mnist_test.npz"),
        "int32_overflow_impossible_for_uint8_inputs": True,
    }
    json_write(verification_dir / "accuracy_report.json", report)
    write_mem(verification_dir / "sample_pixels.mem", images[0], 8)
    write_mem(verification_dir / "expected_digit.mem", predictions[:1], 8)
    write_mem(verification_dir / "sample_expected.mem", predictions[:1], 8)
    write_mem(verification_dir / "test_pixels.mem", images[:20], 8)
    write_mem(verification_dir / "test_expected.mem", predictions[:20], 8)
    write_mem(verification_dir / "test_labels.mem", labels[:20], 8)
    write_mem(verification_dir / "test_hidden.mem", hidden[:20], 8)
    write_mem(verification_dir / "test_logits.mem", logits[:20], 32)
    representative_indices = [int(np.flatnonzero(correct & (labels == digit))[0]) for digit in range(10)]
    write_mem(verification_dir / "representative_pixels.mem", images[representative_indices], 8)
    write_mem(verification_dir / "representative_expected.mem", predictions[representative_indices], 8)
    samples = data_dir / "samples"
    samples.mkdir(exist_ok=True)
    representatives = []
    for digit, index in enumerate(representative_indices):
        stem = f"digit_{digit}_index_{index:05d}"
        Image.fromarray(images[index]).save(samples / f"{stem}.png")
        (samples / f"{stem}.raw").write_bytes(images[index].tobytes(order="C"))
        representatives.append({
            "test_index": index, "label": digit, "reference_prediction": int(predictions[index]),
            "selection": "First correctly predicted example of this label in original test order",
            "png": f"samples/{stem}.png", "raw": f"samples/{stem}.raw",
            "raw_sha256": sha256(samples / f"{stem}.raw"),
        })
    json_write(data_dir / "samples_manifest.json", {
        "purpose": "Convenient demonstration examples, selected for correctness; not an accuracy test",
        "dataset": "mnist_test.npz", "raw_format": "784 unsigned pixel bytes, row-major, no header",
        "samples": representatives,
    })
    json_write(verification_dir / "fixtures_manifest.json", {
        "hex_format": "One value per line; $readmemh-compatible. 8-bit pixels/predictions/hidden, 32-bit two's-complement logits.",
        "sample_pixels.mem": {"shape": [784], "test_index": 0},
        "expected_digit.mem": {"shape": [1], "meaning": "Reference class for original test index0"},
        "sample_expected.mem": {"shape": [1], "meaning": "Alias of expected_digit.mem for UART testbench"},
        "test_pixels.mem": {"shape": [20, 784], "test_indices": list(range(20)), "order": "image then row then column"},
        "test_expected.mem": {"shape": [20], "meaning": "Model predictions, NOT ground-truth labels"},
        "test_labels.mem": {"shape": [20], "meaning": "Ground-truth labels"},
        "test_hidden.mem": {"shape": [20, 32], "order": "image then hidden neuron"},
        "test_logits.mem": {"shape": [20, 10], "order": "image then output neuron"},
        "representative_pixels.mem": {"shape": [10, 784], "test_indices": representative_indices},
        "representative_expected.mem": {"shape": [10], "values": list(range(10))},
    })
    print(f"Integer reference: {int(correct.sum())}/10000 correct ({report['accuracy_percent']:.2f}%), {len(error_indices)} errors")
    print(f"First20 labels:      {labels[:20].tolist()}")
    print(f"First20 predictions: {predictions[:20].tolist()}")
    print(f"Representative indices, digits 0..9: {representative_indices}")
    print(f"Report: {verification_dir / 'accuracy_report.json'}")


if __name__ == "__main__":
    main()
