#!/usr/bin/env python3
"""Generate known-answer vectors for the accelerator tests.

Usage:
    uv run --no-project --with pycryptodome --with ecdsa \\
        tests/eth-act-standards/tools/gen_accel_vectors.py [--out DIR] [--cache DIR]

Writes DIR/<function>.h (default: accelerators/vectors/). The headers are
not checked in: build-guests.sh generates them for every guest build. This
script records where every value comes from.

Sources:
- go-ethereum core/vm/testdata/precompiles, for the EVM precompiles. The
  files are pinned in accel_vector_sources.json: the script downloads each
  file at the pinned commit, checks its sha256 and caches it (default:
  ~/.cache/eth-act-standards-vectors). Their EVM byte encodings are converted
  to the C interface of
  eth-act/zkevm-standards (config.json zkevm_standards_commit):
    * EIP-2537 field elements drop their 16 zero padding bytes (64 -> 48).
    * EIP-196/197 points keep the EVM encoding; G2 is (x_im, x_re, y_im, y_re).
    * Boolean precompile results become the `verified` flag.
- ethereum/execution-specs (EEST) tests/ at tag tests@v20.0.2, also pinned in
  accel_vector_sources.json: the EIP-2537 BLS12-381 vectors, the EIP-7883
  modexp vectors and the EIP-4844 go_kzg_4844_verify_kzg_proof.json vectors.
  Every case of both sources is used when the C interface can express it:
  go-ethereum first, then EEST. A case whose input bytes are already present
  is skipped, and each label starts with its source ("geth" or "eest"). A
  case the fixed-size C types cannot express (a wrong input length, an
  EIP-2537 field element with nonzero padding, an ecrecover v other than 27
  or 28) is skipped; the script prints how many cases it skipped per file.
  KZG outputs map as: true -> TRUE, false -> REJECT, null (an input error)
  -> REJECT; error cases with a wrong field length are skipped, since the C
  types have a fixed size.
- The EEST pytest cases at the same commit, for every precompile that EEST
  keeps as pytest parameters rather than JSON files: ecrecover, ripemd160,
  bn254 (EIP-196/197), blake2f (EIP-152), modexp, point evaluation, the
  EIP-2537 invalid-input cases and P-256 (EIP-7951).
  extract_eest_cases.py writes them to eest_pytest_vectors.json, which is
  checked in, because importing EEST needs its whole Python workspace. Their
  labels start with "eest <test>[<id>]". A point evaluation case whose
  versioned hash does not match the commitment is skipped (the C function
  takes no versioned hash), and so is a modexp case that EEST expects to fail
  (the EIP-7823 input size limit is an EVM rule), and so is a blake2f case
  with a valid input that fails only because the call runs out of gas.
- hashlib/pycryptodome for keccak256, sha256 and ripemd160 digests.
- python-ecdsa for secp256k1 signatures, public-key recovery and checks.

Each case has one expectation:
    OK      status ZKVM_EOK and the output equals the expected bytes
    TRUE    status ZKVM_EOK and verified == true
    REJECT  status ZKVM_EFAIL, or status ZKVM_EOK and verified == false
    EFAIL   status ZKVM_EFAIL (an invalid input to a function with an output)
"""

import argparse
import hashlib
import json
import sys
import urllib.request
from pathlib import Path

import ecdsa
from Crypto.Hash import RIPEMD160, keccak
from ecdsa import ellipticcurve
from ecdsa.util import sigdecode_string, sigencode_string

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "accelerators" / "vectors"
SOURCES = json.loads((Path(__file__).resolve().parent / "accel_vector_sources.json").read_text())["sources"]
EEST_PYTEST = json.loads((Path(__file__).resolve().parent / "eest_pytest_vectors.json").read_text())
CACHE = Path.home() / ".cache" / "eth-act-standards-vectors"

BLS_R = 0x73EDA753299D7D483339D80809A1D80553BDA402FFFE5BFEFFFFFFFF00000001


def pinned_file(source, name):
    """The bytes of a pinned file, downloaded once and checked against its sha256."""
    src = SOURCES[source]
    sha256 = src["files"][name]["sha256"]
    path = CACHE / sha256  # content-addressed, so a changed pin never reuses a stale file
    if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() == sha256:
        return path.read_bytes()
    with urllib.request.urlopen(f"{src['url']}/{name}") as resp:
        data = resp.read()
    if hashlib.sha256(data).hexdigest() != sha256:
        sys.exit(f"error: {source} {name}: sha256 mismatch (expected {sha256})")
    CACHE.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return data


def geth(name):
    return {c["Name"]: c for c in json.loads(pinned_file("go-ethereum", f"{name}.json"))}


def eest(path):
    """An execution-specs vector file: a {Name: case} dict for the geth format, else the raw list."""
    data = json.loads(pinned_file("execution-specs", path))
    return {c["Name"]: c for c in data} if data and "Name" in data[0] else data


def eest_pytest(name):
    """The EEST pytest cases for the go-ethereum vector `name` (see extract_eest_cases.py)."""
    if EEST_PYTEST["execution-specs"] != SOURCES["execution-specs"]["commit"]:
        sys.exit("error: eest_pytest_vectors.json is not at the pinned execution-specs commit; "
                 "run extract_eest_cases.py")
    return {c["Name"]: c for c in EEST_PYTEST["vectors"][name]}


EEST_BLS = "prague/eip2537_bls_12_381_precompiles/vectors/"
EEST_MODEXP = "osaka/eip7883_modexp_gas_increase/vector/"
EEST_KZG = "cancun/eip4844_blobs/point_evaluation_vectors/go_kzg_4844_verify_kzg_proof.json"


SKIPPED = {}


def skip(source):
    """Count a skipped case: the C interface cannot express it, or it fails only by an EVM rule."""
    SKIPPED[source] = SKIPPED.get(source, 0) + 1


def unhex(s):
    return bytes.fromhex(s[2:] if s.startswith("0x") else s)


def keccak256(data):
    return keccak.new(digest_bits=256, data=data).digest()


def pattern(n, seed=0):
    return bytes((i * 131 + seed * 17 + 5) & 0xFF for i in range(n))


# --- C emission -------------------------------------------------------------


def c_array(name, data):
    body = ", ".join(f"0x{b:02x}" for b in data)
    lines = []
    for i in range(0, len(body), 96):
        lines.append("    " + body[i : i + 96].strip())
    joined = "\n".join(lines) if data else "    0"
    return f"_Alignas(8) static const uint8_t {name}[] = {{\n{joined}\n}};\n"


class Header:
    """Collects the byte arrays and case rows for one function."""

    def __init__(self, function, fields, source):
        self.function = function
        self.fields = fields  # (name, kind) with kind "bytes" (ptr + len) or "u32"/"u8"
        self.source = source
        self.arrays = []
        self.rows = []
        self.inputs = set()

    def case(self, label, expect, **values):
        """Add a case, unless a case with the same input bytes exists; returns whether added."""
        key = tuple(values[name] for name, _ in self.fields if name != "out")
        if key in self.inputs:
            return False
        self.inputs.add(key)
        idx = len(self.rows)
        row = [json.dumps(label), f"EXPECT_{expect}"]
        for name, kind in self.fields:
            value = values[name]
            if kind == "bytes":
                array = f"c{idx}_{name}"
                self.arrays.append(c_array(array, value))
                row += [array, str(len(value))]
            else:
                row.append(str(value))
        self.rows.append(row)
        return True

    def write(self):
        if not self.rows:
            sys.exit(f"error: no cases for {self.function}")
        struct_fields = ["    const char *label;", "    int expect;"]
        for name, kind in self.fields:
            if kind == "bytes":
                struct_fields += [f"    const uint8_t *{name};", f"    size_t {name}_len;"]
            else:
                struct_fields.append(f"    uint32_t {name};")
        text = (
            f"/* Generated by tools/gen_accel_vectors.py; do not edit. */\n"
            f"/* {self.function}: {self.source} */\n\n"
            + "".join(self.arrays)
            + "\nstatic const struct {\n"
            + "\n".join(struct_fields)
            + "\n} cases[] = {\n"
            + "".join("    {" + ", ".join(r) + "},\n" for r in self.rows)
            + "};\n"
            + '_Static_assert(sizeof cases / sizeof cases[0] > 0, "no cases");\n'
        )
        OUT.mkdir(parents=True, exist_ok=True)
        (OUT / f"{self.function}.h").write_text(text)


# --- EIP-2537 conversions ---------------------------------------------------


def fp48(fp64):
    assert len(fp64) == 64
    if any(fp64[:16]):
        return None  # a nonzero top byte has no 48-byte encoding
    return fp64[16:]


def fps(data):
    """Strip the padding of every 64-byte field element; None if impossible."""
    out = b""
    for i in range(0, len(data), 64):
        fp = fp48(data[i : i + 64])
        if fp is None:
            return None
        out += fp
    return out


def bls_items(data, item, scalar):
    """Convert k items of (point, [32-byte scalar]) from EIP-2537 layout."""
    size = item + (32 if scalar else 0)
    assert len(data) % size == 0
    out = b""
    for i in range(0, len(data), size):
        point = fps(data[i : i + item])
        if point is None:
            return None
        out += point + (data[i + item : i + size] if scalar else b"")
    return out


# --- generators ---------------------------------------------------------------

HASH_INPUTS = [
    ("empty", b""),
    ("abc", b"abc"),
    ("55 bytes", pattern(55)),
    ("56 bytes", pattern(56)),
    ("64 bytes", pattern(64)),
    ("135 bytes", pattern(135)),
    ("136 bytes", pattern(136)),
    ("137 bytes", pattern(137)),
    ("1000 bytes", pattern(1000, 1)),
]


def gen_hashes():
    digests = {
        "zkvm_keccak256": keccak256,
        "zkvm_sha256": lambda d: hashlib.sha256(d).digest(),
        "zkvm_ripemd160": lambda d: bytes(12) + RIPEMD160.new(d).digest(),
    }
    for function, digest in digests.items():
        h = Header(function, [("data", "bytes"), ("out", "bytes")], "reference digests of fixed inputs")
        for label, data in HASH_INPUTS:
            h.case(label, "OK", data=data, out=digest(data))
        if function == "zkvm_ripemd160":
            h.source += "; execution-specs test_ripemd.py"
            for name, case in eest_pytest("ripemd160").items():
                data = unhex(case["Input"])
                assert bytes(12) + unhex(case["Expected"]) == digest(data), name  # EEST keeps 20 bytes
                h.case(f"eest {name}", "OK", data=data, out=digest(data))
        h.write()


SECP_KEYS = [0x1, 0xC0FFEE, 0x4C0883A69102937D6231471B5DBB6204FE5129617082792AE468D01A3F362318]


def secp_sign(priv, msg):
    sk = ecdsa.SigningKey.from_secret_exponent(priv, curve=ecdsa.SECP256k1)
    digest = keccak256(msg)
    sig = sk.sign_digest_deterministic(digest, hashfunc=hashlib.sha256, sigencode=sigencode_string)
    r, s = sigdecode_string(sig, ecdsa.SECP256k1.order)
    n = ecdsa.SECP256k1.order
    if s > n // 2:
        s = n - s  # Ethereum requires low-s signatures
    pub = sk.get_verifying_key().to_string()
    return digest, r, s, pub


def recover(digest, r, s, recid):
    """The public key that ecrecover returns for recid (the parity of R.y), or None.

    python-ecdsa's recovery fails when the other candidate is the point at
    infinity, so this follows SEC 1 section 4.1.6 directly.
    """
    curve, g, n = ecdsa.SECP256k1.curve, ecdsa.SECP256k1.generator, ecdsa.SECP256k1.order
    p = curve.p()
    if not (0 < r < n and 0 < s < n):
        return None
    y = pow((r**3 + 7) % p, (p + 1) // 4, p)
    if y * y % p != (r**3 + 7) % p:
        return None  # r is not the x-coordinate of a curve point
    if y & 1 != recid:
        y = p - y
    q = ellipticcurve.Point(curve, r, y, n) * s + g * ((n - int.from_bytes(digest, "big")) % n)
    q = q * pow(r, -1, n)
    if q == ellipticcurve.INFINITY:
        return None
    return q.x().to_bytes(32, "big") + q.y().to_bytes(32, "big")


def recid_for(digest, r, s, pub):
    return [recover(digest, r, s, recid) for recid in (0, 1)].index(pub)


def gen_secp256k1():
    n = ecdsa.SECP256k1.order
    rec = Header("zkvm_secp256k1_ecrecover",
                 [("msg", "bytes"), ("sig", "bytes"), ("recid", "u8"), ("out", "bytes")],
                 "python-ecdsa signatures; go-ethereum ecRecover.json and execution-specs "
                 "test_ecrecover.py cross-checked")
    ver = Header("zkvm_secp256k1_verify",
                 [("msg", "bytes"), ("sig", "bytes"), ("pubkey", "bytes")],
                 "python-ecdsa deterministic low-s signatures")
    for i, priv in enumerate(SECP_KEYS):
        digest, r, s, pub = secp_sign(priv, f"act-extra message {i}".encode())
        sig = r.to_bytes(32, "big") + s.to_bytes(32, "big")
        rec.case(f"key {i}", "OK", msg=digest, sig=sig, recid=recid_for(digest, r, s, pub), out=pub)
        ver.case(f"key {i} valid", "TRUE", msg=digest, sig=sig, pubkey=pub)
        if i == 0:
            bad_digest = bytes([digest[0] ^ 1]) + digest[1:]
            ver.case("wrong message", "REJECT", msg=bad_digest, sig=sig, pubkey=pub)
            other = secp_sign(SECP_KEYS[1], b"x")[3]
            ver.case("wrong public key", "REJECT", msg=digest, sig=sig, pubkey=other)
            ver.case("r = 0", "REJECT", msg=digest, sig=bytes(32) + sig[32:], pubkey=pub)
            ver.case("s = n", "REJECT", msg=digest, sig=sig[:32] + n.to_bytes(32, "big"), pubkey=pub)
            not_on_curve = pub[:63] + bytes([pub[63] ^ 1])
            ver.case("public key not on curve", "REJECT", msg=digest, sig=sig, pubkey=not_on_curve)
            rec.case("r = 0", "EFAIL", msg=digest, sig=bytes(32) + sig[32:], recid=0, out=bytes(64))
            rec.case("s = 0", "EFAIL", msg=digest, sig=sig[:32] + bytes(32), recid=0, out=bytes(64))
            rec.case("r = n", "EFAIL", msg=digest, sig=n.to_bytes(32, "big") + sig[32:], recid=0, out=bytes(64))

    for source, cases in (("geth", geth("ecRecover")), ("eest", eest_pytest("ecRecover"))):
        for name, case in cases.items():
            data = unhex(case["Input"]).ljust(128, b"\0")
            digest, v, r, s = data[:32], int.from_bytes(data[32:64], "big"), data[64:96], data[96:128]
            if v not in (27, 28):
                skip(f"{source} ecRecover")  # the C interface takes a recovery id, not an EVM v
                continue
            expected = unhex(case["Expected"])
            if not expected:
                rec.case(f"{source} {name}", "EFAIL", msg=digest, sig=r + s, recid=v - 27, out=bytes(64))
                continue
            pub = recover(digest, int.from_bytes(r, "big"), int.from_bytes(s, "big"), v - 27)
            assert pub is not None and keccak256(pub)[12:] == expected[12:], name
            rec.case(f"{source} {name}", "OK", msg=digest, sig=r + s, recid=v - 27, out=pub)
    rec.write()
    ver.write()


def modexp_parts(data):
    header = data[:96].ljust(96, b"\0")
    blen, elen, mlen = (int.from_bytes(header[i : i + 32], "big") for i in (0, 32, 64))
    body = data[96:].ljust(blen + elen + mlen, b"\0")
    return body[:blen], body[blen : blen + elen], body[blen + elen : blen + elen + mlen]


def gen_modexp():
    h = Header("zkvm_modexp", [("base", "bytes"), ("exp", "bytes"), ("mod", "bytes"), ("out", "bytes")],
               "go-ethereum modexp.json and modexp_eip2565.json, execution-specs EIP-7883 "
               "vectors.json and legacy.json and the modexp pytest cases; edge cases computed with pow()")
    def add(label, case):
        base, exp, mod = modexp_parts(unhex(case["Input"]))
        out = unhex(case["Expected"])
        m = int.from_bytes(mod, "big")
        assert out == (pow(int.from_bytes(base, "big"), int.from_bytes(exp, "big"), m) if m else 0).to_bytes(
            len(mod), "big"), label
        h.case(label, "OK", base=base, exp=exp, mod=mod, out=out)

    for name, case in geth("modexp").items():
        add(f"geth {name}", case)
    for name, case in geth("modexp_eip2565").items():
        add(f"geth eip2565 {name}", case)

    def own(label, base, exp, mod):
        m = int.from_bytes(mod, "big")
        value = 0 if m == 0 else pow(int.from_bytes(base, "big"), int.from_bytes(exp, "big"), m)
        h.case(label, "OK", base=base, exp=exp, mod=mod, out=value.to_bytes(len(mod), "big"))

    for name, case in {**eest(EEST_MODEXP + "vectors.json"), **eest(EEST_MODEXP + "legacy.json")}.items():
        add(f"eest {name}", case)
    for name, case in eest_pytest("modexp").items():
        if not case.get("Success", True):
            skip("eest modexp pytest (expected to fail)")  # the EIP-7823 size limit is an EVM rule
            continue
        add(f"eest {name}", case)

    own("zero modulus gives zero (EVM)", pattern(32, 2), pattern(8, 3), bytes(32))
    own("empty base", b"", pattern(4, 4), pattern(32, 5))
    own("empty exponent gives 1", pattern(32, 6), b"", pattern(32, 7))
    own("modulus 1", pattern(16, 8), pattern(4, 9), b"\x01")
    own("leading zero bytes", bytes(7) + pattern(9, 10), bytes(3) + b"\x05", bytes(5) + pattern(27, 11))
    h.write()


def gen_bn254():
    add = Header("zkvm_bn254_g1_add", [("p1", "bytes"), ("p2", "bytes"), ("out", "bytes")],
                 "go-ethereum bn256Add.json and execution-specs test_ecadd.py (EIP-196); "
                 "inputs padded or cut to 128 bytes, as the EVM does")
    for source, cases in (("geth", geth("bn256Add")), ("eest", eest_pytest("bn256Add"))):
        for name, case in cases.items():
            data, out = unhex(case["Input"]).ljust(128, b"\0")[:128], unhex(case["Expected"])
            add.case(f"{source} {name}", "OK" if out else "EFAIL", p1=data[:64], p2=data[64:], out=out or bytes(64))
    off_curve = (1).to_bytes(32, "big") + (3).to_bytes(32, "big")
    generator = (1).to_bytes(32, "big") + (2).to_bytes(32, "big")
    add.case("point not on curve", "EFAIL", p1=off_curve, p2=generator, out=bytes(64))
    add.write()

    mul = Header("zkvm_bn254_g1_mul", [("point", "bytes"), ("scalar", "bytes"), ("out", "bytes")],
                 "go-ethereum bn256ScalarMul.json and execution-specs test_ecmul.py (EIP-196); "
                 "inputs padded or cut to 96 bytes, as the EVM does")
    for source, cases in (("geth", geth("bn256ScalarMul")), ("eest", eest_pytest("bn256ScalarMul"))):
        for name, case in cases.items():
            data, out = unhex(case["Input"]).ljust(96, b"\0")[:96], unhex(case["Expected"])
            mul.case(f"{source} {name}", "OK" if out else "EFAIL", point=data[:64], scalar=data[64:],
                     out=out or bytes(64))
    mul.case("point not on curve", "EFAIL", point=off_curve, scalar=(2).to_bytes(32, "big"), out=bytes(64))
    mul.write()

    pairing = Header("zkvm_bn254_pairing", [("pairs", "bytes")],
                     "go-ethereum bn256Pairing.json and execution-specs test_ecpairing.py and "
                     "test_ecpairing_fuzzed.py (EIP-197); G2 as (x_im, x_re, y_im, y_re)")
    cases = geth("bn256Pairing")
    for name, case in cases.items():
        verdict = int.from_bytes(unhex(case["Expected"]), "big")
        pairing.case(f"geth {name}", "TRUE" if verdict == 1 else "REJECT", pairs=unhex(case["Input"]))
    for name, case in eest_pytest("bn256Pairing").items():
        data = unhex(case["Input"])
        if len(data) % 192:
            skip("eest bn256Pairing")  # the EVM rejects other lengths; the C function takes whole pairs
            continue
        verdict = int.from_bytes(unhex(case["Expected"]), "big")  # no output: an invalid input
        pairing.case(f"eest {name}", "TRUE" if unhex(case["Expected"]) and verdict == 1 else "REJECT", pairs=data)
    jeff1 = bytearray(unhex(cases["jeff1"]["Input"]))
    jeff1[63] ^= 1
    pairing.case("G1 point not on curve", "REJECT", pairs=bytes(jeff1))
    pairing.write()


def gen_blake2f():
    h = Header("zkvm_blake2f", [("rounds", "u32"), ("h", "bytes"), ("m", "bytes"), ("t", "bytes"),
                                ("f", "u8"), ("out", "bytes")],
               "go-ethereum blake2F.json and fail-blake2f.json, execution-specs test_blake2.py (EIP-152)")

    def split(data):
        return int.from_bytes(data[:4], "big"), data[4:68], data[68:196], data[196:212], data[212]

    for name, case in geth("blake2F").items():
        rounds, hh, m, t, f = split(unhex(case["Input"]))
        h.case(f"geth {name}", "OK", rounds=rounds, h=hh, m=m, t=t, f=f, out=unhex(case["Expected"]))
    for name, case in geth("fail-blake2f").items():
        data = unhex(case["Input"])
        if len(data) != 213:
            skip("geth fail-blake2f")
            continue
        rounds, hh, m, t, f = split(data)
        h.case(f"geth {name}", "EFAIL", rounds=rounds, h=hh, m=m, t=t, f=f, out=hh)
    for name, case in eest_pytest("blake2F").items():
        data, out = unhex(case["Input"]), unhex(case["Expected"])
        if len(data) != 213:
            skip("eest blake2F")
            continue
        rounds, hh, m, t, f = split(data)
        if not out and f in (0, 1):
            skip("eest blake2F (fails only for gas)")  # a valid input; the call runs out of gas
            continue
        h.case(f"eest {name}", "OK" if out else "EFAIL", rounds=rounds, h=hh, m=m, t=t, f=f, out=out or hh)
    h.write()


def gen_kzg():
    h = Header("zkvm_kzg_point_eval", [("commitment", "bytes"), ("z", "bytes"), ("y", "bytes"), ("proof", "bytes")],
               "go-ethereum pointEvaluation.json (EIP-4844) and variants of it, execution-specs "
               "go_kzg_4844_verify_kzg_proof.json and test_point_evaluation_precompile.py")
    data = unhex(geth("pointEvaluation")["pointEvaluation1"]["Input"])
    z, y, commitment, proof = data[32:64], data[64:96], data[96:144], data[144:192]
    h.case("geth pointEvaluation1", "TRUE", commitment=commitment, z=z, y=y, proof=proof)
    y_wrong = (int.from_bytes(y, "big") + 1).to_bytes(32, "big")
    h.case("wrong evaluation", "REJECT", commitment=commitment, z=z, y=y_wrong, proof=proof)
    h.case("z not a field element", "REJECT", commitment=commitment, z=BLS_R.to_bytes(32, "big"), y=y, proof=proof)
    wrong_proof = bytes([proof[0]]) + bytes([proof[1] ^ 1]) + proof[2:]
    h.case("corrupted proof", "REJECT", commitment=commitment, z=z, y=y, proof=wrong_proof)

    # execution-specs (c-kzg-4844 verify_kzg_proof vectors). output true -> TRUE,
    # false -> REJECT, null (an input error) -> REJECT: the C function may return
    # a failure status or verified == false. Error cases with a wrong field
    # length cannot be expressed with the fixed-size C types and are skipped.
    for case in eest(EEST_KZG):
        name = case["name"].removeprefix("verify_kzg_proof_case_")
        fields = {k: unhex(case["input"][k]) for k in ("commitment", "z", "y", "proof")}
        if [len(v) for v in fields.values()] != [48, 32, 32, 48]:
            skip("eest go_kzg_4844_verify_kzg_proof")
            continue
        h.case(f"eest {name}", "TRUE" if case["output"] is True else "REJECT", **fields)

    # execution-specs pytest cases, in the precompile encoding: versioned hash,
    # z, y, commitment, proof. Output 1 -> TRUE, none (an invalid input) -> REJECT.
    for name, case in eest_pytest("pointEvaluation").items():
        data = unhex(case["Input"])
        vh, commitment = data[:32], data[96:144]
        if len(data) != 192 or vh != b"\x01" + hashlib.sha256(commitment).digest()[1:]:
            skip("eest pointEvaluation pytest")  # the C function has no versioned hash and fixed sizes
            continue
        h.case(f"eest {name}", "TRUE" if unhex(case["Expected"]) else "REJECT",
               commitment=commitment, z=data[32:64], y=data[64:96], proof=data[144:192])
    h.write()


# EEST EIP-2537 files per function: (valid files, fail files). The mul_*
# files are single-pair MSMs. Some EEST names are misleading (for example,
# fail-add_G1_bls.json calls a G1 case "bls_g2add_invalid_field_element");
# the labels keep EEST's names.
EEST_BLS_FILES = {
    "zkvm_bls12_g1_add": (["add_G1_bls"], ["fail-add_G1_bls"]),
    "zkvm_bls12_g2_add": (["add_G2_bls"], ["fail-add_G2_bls"]),
    "zkvm_bls12_g1_msm": (["msm_G1_bls", "mul_G1_bls"], ["fail-msm_G1_bls", "fail-mul_G1_bls"]),
    "zkvm_bls12_g2_msm": (["msm_G2_bls", "mul_G2_bls"], ["fail-msm_G2_bls", "fail-mul_G2_bls"]),
    "zkvm_bls12_pairing": (["pairing_check_bls"], ["fail-pairing_check_bls"]),
    "zkvm_bls12_map_fp_to_g1": (["map_fp_to_G1_bls"], ["fail-map_fp_to_G1_bls"]),
    "zkvm_bls12_map_fp2_to_g2": (["map_fp2_to_G2_bls"], ["fail-map_fp2_to_G2_bls"]),
}


def bls_fields(kind, data):
    """Convert an EIP-2537 input to the C fields of `kind`; None if impossible."""
    if kind in ("G1Add", "G2Add"):
        item = 128 if kind == "G1Add" else 256
        if len(data) != 2 * item:
            return None
        p1, p2 = fps(data[:item]), fps(data[item:])
        return None if p1 is None or p2 is None else {"p1": p1, "p2": p2}
    if kind in ("G1MSM", "G2MSM"):
        size = (128 if kind == "G1MSM" else 256) + 32
        if not data or len(data) % size:
            return None
        pairs = bls_items(data, size - 32, True)
        return None if pairs is None else {"pairs": pairs}
    if kind == "Pairing":
        if not data or len(data) % 384:
            return None
        pairs = bls_items(data, 384, False)
        return None if pairs is None else {"pairs": pairs}
    fp = fps(data) if len(data) == (64 if kind == "MapG1" else 128) else None
    return None if fp is None else {"fp": fp}


def add_bls_cases(h, kind, source, valid, fail):
    """Add every valid and every failing case that the C fields can express."""
    out_size = 96 if kind in ("G1Add", "G1MSM", "MapG1") else 192
    for group, cases in (("valid", valid), ("fail", fail)):
        for name, case in cases.items():
            fields = bls_fields(kind, unhex(case["Input"]))
            if fields is None:
                skip(f"{source} {kind} {group}")
                continue
            label = f"{source} {name}"
            if kind == "Pairing":
                ok = group == "valid" and unhex(case["Expected"])[-1] == 1
                h.case(label, "TRUE" if ok else "REJECT", **fields)
            elif group == "valid":
                out = fps(unhex(case["Expected"]))
                assert out is not None, label
                h.case(label, "OK", out=out, **fields)
            else:
                h.case(label, "EFAIL", out=bytes(out_size), **fields)


def gen_bls():
    specs = [
        # function, go-ethereum name, kind
        ("zkvm_bls12_g1_add", "blsG1Add", "G1Add"),
        ("zkvm_bls12_g2_add", "blsG2Add", "G2Add"),
        ("zkvm_bls12_g1_msm", "blsG1MultiExp", "G1MSM"),
        ("zkvm_bls12_g2_msm", "blsG2MultiExp", "G2MSM"),
        ("zkvm_bls12_pairing", "blsPairing", "Pairing"),
        ("zkvm_bls12_map_fp_to_g1", "blsMapG1", "MapG1"),
        ("zkvm_bls12_map_fp2_to_g2", "blsMapG2", "MapG2"),
    ]
    fields = {
        "G1Add": [("p1", "bytes"), ("p2", "bytes"), ("out", "bytes")],
        "G2Add": [("p1", "bytes"), ("p2", "bytes"), ("out", "bytes")],
        "G1MSM": [("pairs", "bytes"), ("out", "bytes")],
        "G2MSM": [("pairs", "bytes"), ("out", "bytes")],
        "Pairing": [("pairs", "bytes")],
        "MapG1": [("fp", "bytes"), ("out", "bytes")],
        "MapG2": [("fp", "bytes"), ("out", "bytes")],
    }
    for function, name, kind in specs:
        h = Header(function, fields[kind],
                   f"go-ethereum {name}.json and fail-{name}.json, execution-specs EIP-2537 vectors "
                   "and pytest cases")
        add_bls_cases(h, kind, "geth", geth(name), geth("fail-" + name))
        valid_files, fail_files = EEST_BLS_FILES[function]
        load = lambda files: {n: c for f in files for n, c in eest(f"{EEST_BLS}{f}.json").items()}
        add_bls_cases(h, kind, "eest", load(valid_files), load(fail_files))
        # The pytest cases; no output means an invalid input. G1/G2 mul cases are single-pair MSMs.
        for key in [name] + {"G1MSM": ["blsG1Mul"], "G2MSM": ["blsG2Mul"]}.get(kind, []):
            cases = {f"{key} {n}": c for n, c in eest_pytest(key).items()}
            add_bls_cases(h, kind, "eest", {n: c for n, c in cases.items() if c["Expected"]},
                          {n: c for n, c in cases.items() if not c["Expected"]})
        h.write()


def gen_p256():
    h = Header("zkvm_secp256r1_verify", [("msg", "bytes"), ("sig", "bytes"), ("pubkey", "bytes")],
               "go-ethereum p256Verify.json (EIP-7212, Wycheproof-derived), execution-specs "
               "test_p256verify.py (EIP-7951)")
    for n, c in geth("p256Verify").items():
        data = unhex(c["Input"])
        if len(data) != 160:
            skip("geth p256Verify")  # EIP-7212 rejects other lengths; the C types are fixed-size
            continue
        expect = "TRUE" if unhex(c["Expected"]) else "REJECT"
        label = n.split(": ", 1)[-1] if ": " in n else n
        h.case(f"geth {label}", expect, msg=data[:32], sig=data[32:96], pubkey=data[96:160])
    for name, case in eest_pytest("p256Verify").items():
        data = unhex(case["Input"])
        if len(data) != 160:
            skip("eest p256Verify")
            continue
        expect = "TRUE" if unhex(case["Expected"]) else "REJECT"
        h.case(f"eest {name}", expect, msg=data[:32], sig=data[32:96], pubkey=data[96:160])
    h.write()


def main():
    global OUT, CACHE
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--out", type=Path, default=OUT, help="directory for the <function>.h headers")
    parser.add_argument("--cache", type=Path, default=CACHE, help="download cache for the pinned files")
    args = parser.parse_args()
    OUT, CACHE = args.out, args.cache
    gen_hashes()
    gen_secp256k1()
    gen_modexp()
    gen_bn254()
    gen_blake2f()
    gen_kzg()
    gen_bls()
    gen_p256()
    for source, count in sorted(SKIPPED.items()):
        print(f"skipped {count:4d} cases: {source}")


if __name__ == "__main__":
    main()
