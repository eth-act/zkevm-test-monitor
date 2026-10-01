#!/usr/bin/env python3
"""Extract the EEST pytest precompile cases into eest_pytest_vectors.json.

Usage (in an ethereum/execution-specs checkout at the commit that
accel_vector_sources.json pins for "execution-specs"):
    uv run python <this dir>/extract_eest_cases.py [--out FILE]

EEST keeps most precompile cases as pytest parameters, not as JSON vector
files. This script imports the test modules below, expands their
pytest.mark.parametrize marks, and writes each case in the go-ethereum vector
format: {"Name", "Input", "Expected"} with hex strings. "Expected" is "" when
the call returns no data (an invalid input). Inputs that are already in the
pinned EEST JSON vector files are left out. Modexp cases also carry
"Success": false when EEST expects the call to fail. gen_accel_vectors.py reads
the output; importing EEST needs its whole workspace, so the guest build uses
the committed output instead of running this script.
"""

import argparse
import importlib
import itertools
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SOURCES = json.loads((HERE / "accel_vector_sources.json").read_text())["sources"]
OUT = HERE / "eest_pytest_vectors.json"

BLS = "prague.eip2537_bls_12_381_precompiles."
P256 = "osaka.eip7951_p256verify_precompiles.test_p256verify"

# go-ethereum vector name -> (module, test functions). Tests that vary only the
# gas, the call opcode or the fork are left out: their inputs repeat these.
# test_external_vectors (point evaluation) only reads a pinned JSON file.
TESTS = {
    "ecRecover": [("frontier.precompiles.test_ecrecover", ["test_precompiles"])],
    "ripemd160": [("frontier.precompiles.test_ripemd", ["test_precompiles"])],
    "bn256Add": [("byzantium.eip196_ec_add_mul.test_ecadd", ["test_valid", "test_invalid"])],
    "bn256ScalarMul": [("byzantium.eip196_ec_add_mul.test_ecmul", ["test_valid", "test_invalid"])],
    "bn256Pairing": [
        ("byzantium.eip197_ec_pairing.test_ecpairing", ["test_valid", "test_fail", "test_invalid"]),
        ("byzantium.eip197_ec_pairing.test_ecpairing_fuzzed",
         ["test_positive", "test_negative", "test_invalid_g1_point", "test_invalid_g2_point",
          "test_invalid_g2_subgroup"]),
    ],
    "blake2F": [("istanbul.eip152_blake2.test_blake2",
                 ["test_blake2b", "test_blake2b_invalid_input", "test_blake2b_large_gas_limit"])],
    "modexp": [
        ("byzantium.eip198_modexp_precompile.test_modexp", ["test_modexp"]),
        ("osaka.eip7823_modexp_upper_bounds.test_modexp_upper_bounds", ["test_modexp_upper_bounds"]),
        ("osaka.eip7883_modexp_gas_increase.test_modexp_thresholds",
         ["test_modexp_boundary_inputs", "test_modexp_invalid_inputs", "test_modexp_legacy_oversized_inputs"]),
    ],
    "pointEvaluation": [("cancun.eip4844_blobs.test_point_evaluation_precompile",
                         ["test_valid_inputs", "test_invalid_inputs"])],
    "blsG1Add": [(BLS + "test_bls12_g1add", ["test_valid", "test_invalid"])],
    "blsG2Add": [(BLS + "test_bls12_g2add", ["test_valid", "test_invalid"])],
    "blsG1Mul": [(BLS + "test_bls12_g1mul", ["test_valid", "test_invalid"])],
    "blsG2Mul": [(BLS + "test_bls12_g2mul", ["test_valid", "test_invalid"])],
    "blsG1MultiExp": [(BLS + "test_bls12_g1msm", ["test_valid", "test_invalid"])],
    "blsG2MultiExp": [(BLS + "test_bls12_g2msm", ["test_valid", "test_invalid"])],
    "blsMapG1": [(BLS + "test_bls12_map_fp_to_g1", ["test_valid", "test_invalid"])],
    "blsMapG2": [(BLS + "test_bls12_map_fp2_to_g2", ["test_valid", "test_invalid"])],
    "blsPairing": [(BLS + "test_bls12_pairing", ["test_valid", "test_invalid"])],
    "p256Verify": [(P256, ["test_valid", "test_invalid", "test_wycheproof_valid", "test_wycheproof_invalid",
                           "test_wycheproof_extra", "test_modular_comparison"])],
}


def parametrize(fn):
    """Yield (id, {argname: value}) for every combination of fn's parametrize marks."""
    groups = []
    for mark in getattr(fn, "pytestmark", []):
        if mark.name != "parametrize":
            continue
        names = mark.args[0]
        names = [n.strip() for n in (names.split(",") if isinstance(names, str) else names) if n.strip()]
        rows = []
        for i, value in enumerate(list(mark.args[1])):
            pid = None
            if hasattr(value, "values") and hasattr(value, "id"):  # pytest.param
                pid, value = value.id, value.values
            elif len(names) == 1:
                value = (value,)
            rows.append((pid if isinstance(pid, str) else str(i), dict(zip(names, value))))
        groups.append(rows)
    for combo in itertools.product(*groups):
        values = {}
        for _, v in combo:
            values.update(v)
        yield "-".join(pid for pid, _ in combo), values


def word(value, size=32):
    return value.to_bytes(size, "big") if isinstance(value, int) else bytes(value)


def encode(name, v):
    """(input, expected, success) of one case, in the EVM precompile encoding."""
    if name == "ecRecover":
        return word(v["msg_hash"]) + word(v["v"]) + word(v["r"]) + word(v["s"]), bytes(v["output"]), None
    if name == "ripemd160":
        return bytes(v["msg"]), bytes(v["output"]), None
    if name == "blake2F":
        out = v.get("output")
        # EEST stores the output as two storage words, so leading zero digits are dropped.
        return bytes(v["data"]), word(int(out.data_1, 16)) + word(int(out.data_2, 16)) if out else b"", None
    if name == "modexp":
        out = v.get("output", v.get("modexp_expected"))
        success = v.get("call_succeeds", getattr(out, "call_success", True))
        return bytes(v.get("mod_exp_input", v.get("modexp_input"))), bytes(out), success
    if name == "pointEvaluation":
        # As the test module's precompile_input fixture encodes it.
        mod = importlib.import_module("tests." + TESTS[name][0][0])
        z, y = (x.to_bytes(32, mod.Z_Y_VALID_ENDIANNESS) if isinstance(x, int) else bytes(x) for x in (v["z"], v["y"]))
        commitment, proof = word(v["kzg_commitment"], 48), word(v["kzg_proof"], 48)
        vh = v["versioned_hash"]
        vh = mod.Spec.kzg_to_versioned_hash(commitment) if vh is None else word(vh)
        return vh + z + y + commitment + proof, b"\x01" if v["result"].name == "SUCCESS" else b"", None
    return bytes(v["input_data"]), bytes(v["expected_output"]), None


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--out", type=Path, default=OUT)
    args = parser.parse_args()
    commit = SOURCES["execution-specs"]["commit"]
    head = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
    if head != commit:
        sys.exit(f"error: run in an execution-specs checkout at {commit} (HEAD is {head})")
    sys.path.insert(0, ".")
    # Some tests also read the pinned JSON vector files; gen_accel_vectors.py
    # reads those directly, so their inputs are left out here.
    pinned = set()
    for path in SOURCES["execution-specs"]["files"]:
        data = json.loads(Path("tests", path).read_text())
        pinned |= {bytes.fromhex(c["Input"].removeprefix("0x")) for c in data if "Input" in c}
    vectors = {}
    for name, modules in TESTS.items():
        cases = vectors.setdefault(name, [])
        seen = set()
        for module, tests in modules:
            mod = importlib.import_module("tests." + module)
            for test in tests:
                for pid, values in parametrize(getattr(mod, test)):
                    data, expected, success = encode(name, values)
                    if data in seen or data in pinned:  # another gas or call variant, or a pinned file
                        continue
                    seen.add(data)
                    case = {"Name": f"{test}[{pid}]", "Input": data.hex(), "Expected": expected.hex()}
                    if success is not None:
                        case["Success"] = bool(success)
                    cases.append(case)
        print(f"{len(cases):5d} {name}")
    # One case per line, so a change of the pin gives a readable diff.
    lines = [f'{{"execution-specs": "{commit}", "vectors": {{']
    for i, (name, cases) in enumerate(vectors.items()):
        lines.append(f" {json.dumps(name)}: [")
        lines += [f"  {json.dumps(c)}" + ("," if j < len(cases) - 1 else "") for j, c in enumerate(cases)]
        lines.append(" ]" + ("," if i < len(vectors) - 1 else ""))
    args.out.write_text("\n".join(lines) + "\n}}\n")


if __name__ == "__main__":
    main()
