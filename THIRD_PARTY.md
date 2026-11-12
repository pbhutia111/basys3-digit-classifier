# Third-party sources and data

## Current Verilog inference core

- Source: https://github.com/ZakriyaParacha46/neural-net-on-fpga
- Pinned revision: `ff9af3f63a329d7ad5e6b93a1d7d21ff8d84686e`
- Location: `repos/neural-net-on-fpga` (Git submodule)
- License: MIT; copyright (c) 2026 Zakriya Paracha. The original license is
  retained in the submodule's `LICENSE` file.

The inference engine, ROM modules, and pretrained weights come from that source.
This project adds the Basys 3 UART/display integration, host tools, and checks;
it does not claim original authorship of the upstream network or weights.

## Earlier VHDL project

- Source: https://github.com/InduwaraGunasena/SNN-FPGA
- Pinned revision: `ff4218e089740087a16321b5b74d75354e3f140b`
- Location: `repos/SNN-FPGA` (Git submodule)

The submodule preserves its original source and notices. Refer to the upstream
repository for the terms covering its VHDL, training material, and weights.

## MNIST data and fixtures

MNIST is by Yann LeCun and Corinna Cortes, derived from NIST. The local test
archive was extracted from the Keras-hosted MNIST archive:
https://storage.googleapis.com/tensorflow/tf-keras-datasets/mnist.npz

The dataset manifest records CC BY-SA 3.0 as documented by Keras:
https://creativecommons.org/licenses/by-sa/3.0/

`verilog-uart/data/mnist_test.npz` retains the original 10,000 test images and
labels; the training split is excluded. PNG/raw demonstration samples and
simulation memory fixtures are exports of selected test pixels. Sample indices,
hashes, and transformations are recorded in `data/dataset_manifest.json`,
`data/samples_manifest.json`, and `verification/fixtures_manifest.json` under
`verilog-uart/`. The dataset's terms apply to these data assets.

## Board constraints

Pin assignments reference Digilent's Basys 3 master constraints:
https://github.com/Digilent/digilent-xdc/blob/master/Basys-3-Master.xdc

Each upstream component retains its own licensing terms; publishing this
integration does not replace those terms.
