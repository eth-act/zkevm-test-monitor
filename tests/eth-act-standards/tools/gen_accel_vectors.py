#!/usr/bin/env python3
"""Generate known-answer vectors for the accelerator tests.

Usage (from the repository root):
    uv run --no-project --with pycryptodome --with ecdsa \\
        tests/eth-act-standards/tools/gen_accel_vectors.py

Writes tests/eth-act-standards/accelerators/vectors/<function>.h. The headers are checked
in; this script records where every value comes from and regenerates them.

Sources:
- go-ethereum core/vm/testdata/precompiles, for the EVM precompiles. The
  files are pinned in accel_vector_sources.json: the script downloads each
  file at the pinned commit, checks its sha256 and caches it in
  ~/.cache/eth-act-standards-vectors. Their EVM byte encodings are converted
  to the C interface of
  eth-act/zkevm-standards (config.json zkevm_standards_commit):
    * EIP-2537 field elements drop their 16 zero padding bytes (64 -> 48).
    * EIP-196/197 points keep the EVM encoding; G2 is (x_im, x_re, y_im, y_re).
    * Boolean precompile results become the `verified` flag.
- ethereum/execution-specs (EEST) tests/ at tag tests@v20.0.2, also pinned in
  accel_vector_sources.json: the EIP-2537 BLS12-381 vectors, the EIP-7883
  modexp vectors and the EIP-4844 go_kzg_4844_verify_kzg_proof.json vectors.
  The two sources are combined: every go-ethereum pick stays, and selected
  EEST cases are added. A case whose input bytes are already present is
  skipped, and each label starts with its source ("geth" or "eest").
  KZG outputs map as: true -> TRUE, false -> REJECT, null (an input error)
  -> REJECT; error cases with a wrong field length are skipped, since the C
  types have a fixed size.
  bn254 (EIP-196/197), blake2f (EIP-152) and ecrecover stay go-ethereum only:
  EEST has these tests only as Python pytest parameters, not as JSON vectors.
- hashlib/pycryptodome for keccak256, sha256 and ripemd160 digests.
- python-ecdsa for secp256k1 signatures, public-key recovery and checks.

Each case has one expectation:
    OK      status ZKVM_EOK and the output equals the expected bytes
    TRUE    status ZKVM_EOK and verified == true
    REJECT  status ZKVM_EFAIL, or status ZKVM_EOK and verified == false
    EFAIL   status ZKVM_EFAIL (an invalid input to a function with an output)
"""

import hashlib
import json
import sys
import urllib.request
from pathlib import Path

import ecdsa
from Crypto.Hash import RIPEMD160, keccak
from ecdsa.util import sigdecode_string, sigencode_string

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "accelerators" / "vectors"
SOURCES = json.loads((Path(__file__).resolve().parent / "accel_vector_sources.json").read_text())["sources"]
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


EEST_BLS = "prague/eip2537_bls_12_381_precompiles/vectors/"
EEST_MODEXP = "osaka/eip7883_modexp_gas_increase/vector/"
EEST_KZG = "cancun/eip4844_blobs/point_evaluation_vectors/go_kzg_4844_verify_kzg_proof.json"


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
        row = [f'"{label}"', f"EXPECT_{expect}"]
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


def recover_candidates(digest, r, s):
    sig = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    return [vk.to_string() for vk in ecdsa.VerifyingKey.from_public_key_recovery_with_digest(
        sig, digest, ecdsa.SECP256k1, sigdecode=sigdecode_string, allow_truncate=False)]


def recid_for(digest, r, s, pub):
    """Recovery id: parity of R.y. python-ecdsa returns candidates in that order."""
    candidates = recover_candidates(digest, r, s)
    return candidates.index(pub)


def gen_secp256k1():
    n = ecdsa.SECP256k1.order
    rec = Header("zkvm_secp256k1_ecrecover",
                 [("msg", "bytes"), ("sig", "bytes"), ("recid", "u8"), ("out", "bytes")],
                 "python-ecdsa signatures; go-ethereum ecRecover.json cross-checked")
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

    for name, case in geth("ecRecover").items():
        data = unhex(case["Input"]).ljust(128, b"\0")
        digest, v, r, s = data[:32], int.from_bytes(data[32:64], "big"), data[64:96], data[96:128]
        if v not in (27, 28):
            continue  # the C interface takes a recovery id, not an EVM v
        expected = unhex(case["Expected"])
        if not expected:
            rec.case(f"geth {name}", "EFAIL", msg=digest, sig=r + s, recid=v - 27, out=bytes(64))
            continue
        pub = recover_candidates(digest, int.from_bytes(r, "big"), int.from_bytes(s, "big"))[v - 27]
        assert keccak256(pub)[12:] == expected[12:], name
        rec.case(f"geth {name}", "OK", msg=digest, sig=r + s, recid=v - 27, out=pub)
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
               "vectors.json and legacy.json; edge cases computed with pow()")
    cases = {**geth("modexp"), **{f"eip2565 {k}": v for k, v in geth("modexp_eip2565").items()}}
    for name in ["eip_example1", "eip_example2", "nagydani-1-square", "nagydani-1-pow0x10001",
                 "nagydani-2-qube", "eip2565 marius-1-even", "eip2565 guido-4-even",
                 "eip2565 marcin-1-exp-heavy", "eip2565 mod_vul_pawel_3_exp_8"]:
        base, exp, mod = modexp_parts(unhex(cases[name]["Input"]))
        out = unhex(cases[name]["Expected"])
        assert out == pow(int.from_bytes(base, "big"), int.from_bytes(exp, "big"),
                          int.from_bytes(mod, "big")).to_bytes(len(mod), "big"), name
        h.case(f"geth {name}", "OK", base=base, exp=exp, mod=mod, out=out)

    def own(label, base, exp, mod):
        m = int.from_bytes(mod, "big")
        value = 0 if m == 0 else pow(int.from_bytes(base, "big"), int.from_bytes(exp, "big"), m)
        h.case(label, "OK", base=base, exp=exp, mod=mod, out=value.to_bytes(len(mod), "big"))

    eest_cases = {**eest(EEST_MODEXP + "vectors.json"), **eest(EEST_MODEXP + "legacy.json")}
    for name in ["zero-exponent-32bytes", "zero-length-base-mod", "unequal-base-mod-lengths",
                 "word-boundary-7bytes", "32byte-boundary-31-32-33", "exponent-with-leading-zeros",
                 "large-exponent-80bytes", "256byte-all-params", "legacy-case-10", "legacy-case-13",
                 "legacy-case-27", "legacy-case-33"]:
        base, exp, mod = modexp_parts(unhex(eest_cases[name]["Input"]))
        out = unhex(eest_cases[name]["Expected"])
        m = int.from_bytes(mod, "big")
        assert out == (pow(int.from_bytes(base, "big"), int.from_bytes(exp, "big"), m) if m else 0).to_bytes(
            len(mod), "big"), name
        h.case(f"eest {name}", "OK", base=base, exp=exp, mod=mod, out=out)

    own("zero modulus gives zero (EVM)", pattern(32, 2), pattern(8, 3), bytes(32))
    own("empty base", b"", pattern(4, 4), pattern(32, 5))
    own("empty exponent gives 1", pattern(32, 6), b"", pattern(32, 7))
    own("modulus 1", pattern(16, 8), pattern(4, 9), b"\x01")
    own("leading zero bytes", bytes(7) + pattern(9, 10), bytes(3) + b"\x05", bytes(5) + pattern(27, 11))
    h.write()


def gen_bn254():
    add = Header("zkvm_bn254_g1_add", [("p1", "bytes"), ("p2", "bytes"), ("out", "bytes")],
                 "go-ethereum bn256Add.json (EIP-196), inputs of exactly 128 bytes")
    for name, case in geth("bn256Add").items():
        data = unhex(case["Input"])
        if len(data) == 128:
            add.case(f"geth {name}", "OK", p1=data[:64], p2=data[64:], out=unhex(case["Expected"]))
    off_curve = (1).to_bytes(32, "big") + (3).to_bytes(32, "big")
    generator = (1).to_bytes(32, "big") + (2).to_bytes(32, "big")
    add.case("point not on curve", "EFAIL", p1=off_curve, p2=generator, out=bytes(64))
    add.write()

    mul = Header("zkvm_bn254_g1_mul", [("point", "bytes"), ("scalar", "bytes"), ("out", "bytes")],
                 "go-ethereum bn256ScalarMul.json (EIP-196), inputs of exactly 96 bytes")
    for name, case in geth("bn256ScalarMul").items():
        data = unhex(case["Input"])
        if len(data) == 96:
            mul.case(f"geth {name}", "OK", point=data[:64], scalar=data[64:], out=unhex(case["Expected"]))
    mul.case("point not on curve", "EFAIL", point=off_curve, scalar=(2).to_bytes(32, "big"), out=bytes(64))
    mul.write()

    pairing = Header("zkvm_bn254_pairing", [("pairs", "bytes")],
                     "go-ethereum bn256Pairing.json (EIP-197); G2 as (x_im, x_re, y_im, y_re)")
    cases = geth("bn256Pairing")
    for name in ["jeff1", "jeff2", "jeff6", "empty_data", "one_point", "two_point_match_2",
                 "two_point_match_3", "ten_point_match_1"]:
        verdict = int.from_bytes(unhex(cases[name]["Expected"]), "big")
        pairing.case(f"geth {name}", "TRUE" if verdict == 1 else "REJECT", pairs=unhex(cases[name]["Input"]))
    jeff1 = bytearray(unhex(cases["jeff1"]["Input"]))
    jeff1[63] ^= 1
    pairing.case("G1 point not on curve", "REJECT", pairs=bytes(jeff1))
    pairing.write()


def gen_blake2f():
    h = Header("zkvm_blake2f", [("rounds", "u32"), ("h", "bytes"), ("m", "bytes"), ("t", "bytes"),
                                ("f", "u8"), ("out", "bytes")],
               "go-ethereum blake2F.json and fail-blake2f.json (EIP-152)")

    def split(data):
        return int.from_bytes(data[:4], "big"), data[4:68], data[68:196], data[196:212], data[212]

    for name, case in geth("blake2F").items():
        rounds, hh, m, t, f = split(unhex(case["Input"]))
        h.case(f"geth {name}", "OK", rounds=rounds, h=hh, m=m, t=t, f=f, out=unhex(case["Expected"]))
    for name, case in geth("fail-blake2f").items():
        data = unhex(case["Input"])
        if len(data) == 213:
            rounds, hh, m, t, f = split(data)
            h.case(f"geth {name}", "EFAIL", rounds=rounds, h=hh, m=m, t=t, f=f, out=hh)
    h.write()


def gen_kzg():
    h = Header("zkvm_kzg_point_eval", [("commitment", "bytes"), ("z", "bytes"), ("y", "bytes"), ("proof", "bytes")],
               "go-ethereum pointEvaluation.json (EIP-4844) and variants of it, execution-specs "
               "go_kzg_4844_verify_kzg_proof.json")
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
    per_kind = {"correct_proof": 2, "correct_proof_point_at_infinity_for_twos_poly": 1,
                "correct_proof_point_at_infinity_for_zero_poly": 1, "incorrect_proof": 2,
                "incorrect_proof_point_at_infinity": 1, "invalid_commitment": 99, "invalid_proof": 99,
                "invalid_y": 99, "invalid_z": 99}
    taken = {}
    for case in eest(EEST_KZG):
        name = case["name"].removeprefix("verify_kzg_proof_case_")
        kind = name.rsplit("_", 1)[0]
        fields = {k: unhex(case["input"][k]) for k in ("commitment", "z", "y", "proof")}
        if [len(v) for v in fields.values()] != [48, 32, 32, 48] or taken.get(kind, 0) >= per_kind[kind]:
            continue
        if h.case(f"eest {name}", "TRUE" if case["output"] is True else "REJECT", **fields):
            taken[kind] = taken.get(kind, 0) + 1
    h.write()


def take(cases, count, predicate=lambda c: True):
    return [(n, c) for n, c in cases.items() if predicate(c)][:count]


# EEST picks per function: (valid files, valid names, fail files, fail names).
# Cases whose input bytes are already present (most EEST cases are also in
# go-ethereum) are skipped by Header.case. Three EEST names are misleading:
# fail-add_G1_bls.json calls its G1 invalid-field-element case
# "bls_g2add_invalid_field_element", and msm_G2_bls.json calls its G2
# infinity case "bls_g1msm_(inf+inf)", and fail-msm_G2_bls.json calls its
# G2 subgroup case "bls_pairing_g2_not_in_correct_subgroup"; the labels keep
# EEST's names.
EEST_BLS_PICKS = {
    "zkvm_bls12_g1_add": (
        ["add_G1_bls"], ["bls_g1add_g1+p1", "bls_g1add_(g1+0=g1)", "bls_g1add_(g1-g1=0)"],
        ["fail-add_G1_bls"], ["bls_g1add_point_not_on_curve", "bls_g2add_invalid_field_element"]),
    "zkvm_bls12_g2_add": (
        ["add_G2_bls"], ["bls_g2add_g2+p2", "bls_g2add_(g2+0=g2)", "bls_g2add_(g2-g2=0)"],
        ["fail-add_G2_bls"], ["bls_g2add_point_not_on_curve", "bls_g2add_invalid_field_element"]),
    "zkvm_bls12_g1_msm": (
        ["msm_G1_bls", "mul_G1_bls"],
        ["bls_g1msm_(0*g1=inf)", "bls_g1msm_(x*inf=inf)", "bls_g1msm_(2g1+inf)", "bls_g1msm_(inf+inf)",
         "bls_g1msm_(2g1+2p1)", "bls_g1msm_multiple_with_point_at_infinity",
         "bls_g1msm_random*g1_unnormalized_scalar", "bls_g1mul_random*g1"],
        ["fail-msm_G1_bls", "fail-mul_G1_bls"],
        ["bls_g1msm_invalid_field_element", "bls_g1msm_point_not_on_curve",
         "bls_g1msm_g1_not_in_correct_subgroup", "bls_g1mul_g1_not_in_correct_subgroup"]),
    "zkvm_bls12_g2_msm": (
        ["msm_G2_bls", "mul_G2_bls"],
        ["bls_g2msm_(0*g2=inf)", "bls_g2msm_(x*inf=inf)", "bls_g2msm_(2g2+inf)", "bls_g1msm_(inf+inf)",
         "bls_g2msm_(2g2+2p2)", "bls_g2msm_multiple_with_point_at_infinity",
         "bls_g2msm_random*g2_unnormalized_scalar", "bls_g2mul_random*g2"],
        ["fail-msm_G2_bls", "fail-mul_G2_bls"],
        ["bls_g2msm_invalid_field_element", "bls_g2msm_point_not_on_curve",
         "bls_pairing_g2_not_in_correct_subgroup", "bls_g2mul_g2_not_in_correct_subgroup"]),
    "zkvm_bls12_pairing": (
        ["pairing_check_bls"],
        ["bls_pairing_e(0,0)", "bls_pairing_e(0,0)=e(0,0)", "bls_pairing_e(0,G2)", "bls_pairing_e(G1,0)",
         "bls_pairing_e(0,-G2)!=e(-G1,G2)", "bls_pairing_e(G1,0)!=e(-G1,G2)",
         "bls_pairing_e(G1,G2)*e(0,0)*e(G1,-G2)=1", "bls_pairing_e(G1,G2)*e(0,0)*e(G1,G2)=0"],
        ["fail-pairing_check_bls"],
        ["bls_pairing_e(G1_field_element_equal_to_modulus,G2)", "bls_pairing_e(G1_invalid_field_element,G2)",
         "bls_pairing_e(G1,G2_invalid_field_element)", "bls_pairing_e(G1_not_on_curve,G2)",
         "bls_pairing_e(G1,G2_not_on_curve)", "bls_pairing_e(G1_not_in_correct_subgroup,G2)",
         "bls_pairing_e(G1,G2_not_in_correct_subgroup)", "bls_pairing_e(G1_not_in_correct_subgroup,0)",
         "bls_pairing_e(0,G2_not_in_correct_subgroup)"]),
    "zkvm_bls12_map_fp_to_g1": (["map_fp_to_G1_bls"], ["bls_g1map_616263", "bls_g1map_6162636465663031"], [], []),
    "zkvm_bls12_map_fp2_to_g2": (["map_fp2_to_G2_bls"], ["bls_g2map_616263", "bls_g2map_6162636465663031"], [], []),
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


def add_eest_bls(h, function, kind):
    valid_files, valid_names, fail_files, fail_names = EEST_BLS_PICKS[function]
    load = lambda files: {n: c for f in files for n, c in eest(f"{EEST_BLS}{f}.json").items()}
    valid, fail = load(valid_files), load(fail_files)
    out_size = 96 if kind in ("G1Add", "G1MSM", "MapG1") else 192
    for name in valid_names + fail_names:
        ok = name in valid_names
        case = (valid if ok else fail)[name]
        fields = bls_fields(kind, unhex(case["Input"]))
        assert fields is not None, name
        if kind == "Pairing":
            expect = "TRUE" if ok and unhex(case["Expected"])[-1] == 1 else "REJECT"
            h.case(f"eest {name}", expect, **fields)
        else:
            out = fps(unhex(case["Expected"])) if ok else bytes(out_size)
            h.case(f"eest {name}", "OK" if ok else "EFAIL", out=out, **fields)


def gen_bls():
    specs = [
        # function, geth name, point size (EIP-2537 bytes), fields, splitter
        ("zkvm_bls12_g1_add", "blsG1Add", "G1Add"),
        ("zkvm_bls12_g2_add", "blsG2Add", "G2Add"),
        ("zkvm_bls12_g1_msm", "blsG1MultiExp", "G1MSM"),
        ("zkvm_bls12_g2_msm", "blsG2MultiExp", "G2MSM"),
        ("zkvm_bls12_pairing", "blsPairing", "Pairing"),
        ("zkvm_bls12_map_fp_to_g1", "blsMapG1", "MapG1"),
        ("zkvm_bls12_map_fp2_to_g2", "blsMapG2", "MapG2"),
    ]
    for function, name, kind in specs:
        valid = geth(name)
        fail = geth("fail-" + name)
        if kind in ("G1Add", "G2Add"):
            item = 128 if kind == "G1Add" else 256
            h = Header(function, [("p1", "bytes"), ("p2", "bytes"), ("out", "bytes")],
                       f"go-ethereum {name}.json and fail-{name}.json, execution-specs EIP-2537 vectors")

            def emit(label, data, expect, out):
                p1, p2 = fps(data[:item]), fps(data[item:])
                if p1 is not None and p2 is not None:
                    h.case(label, expect, p1=p1, p2=p2, out=out)

            for n, c in take(valid, 6):
                emit(f"geth {n}", unhex(c["Input"]), "OK", fps(unhex(c["Expected"])))
            for n, c in fail.items():
                if len(unhex(c["Input"])) == 2 * item:
                    emit(f"geth {n}", unhex(c["Input"]), "EFAIL", bytes(item * 3 // 4))
        elif kind in ("G1MSM", "G2MSM"):
            item = 128 if kind == "G1MSM" else 256
            size = item + 32
            h = Header(function, [("pairs", "bytes"), ("out", "bytes")],
                       f"go-ethereum {name}.json and fail-{name}.json, execution-specs EIP-2537 vectors")
            singles = take(valid, 3, lambda c: len(unhex(c["Input"])) == size)
            multis = take(valid, 3, lambda c: len(unhex(c["Input"])) > size)
            for n, c in singles + multis:
                h.case(f"geth {n} (k={len(unhex(c['Input'])) // size})", "OK",
                       pairs=bls_items(unhex(c["Input"]), item, True), out=fps(unhex(c["Expected"])))
            for n, c in fail.items():
                data = unhex(c["Input"])
                if data and len(data) % size == 0:
                    pairs = bls_items(data, item, True)
                    if pairs is not None:
                        h.case(f"geth {n}", "EFAIL", pairs=pairs, out=bytes(item * 3 // 4))
        elif kind == "Pairing":
            h = Header(function, [("pairs", "bytes")],
                       f"go-ethereum {name}.json and fail-{name}.json, execution-specs EIP-2537 vectors")

            def convert(data):
                out = b""
                for i in range(0, len(data), 384):
                    g1, g2 = fps(data[i : i + 128]), fps(data[i + 128 : i + 384])
                    if g1 is None or g2 is None:
                        return None
                    out += g1 + g2
                return out

            ones = take(valid, 3, lambda c: unhex(c["Expected"])[-1] == 1)
            zeros = take(valid, 2, lambda c: unhex(c["Expected"])[-1] == 0)
            for n, c in ones + zeros:
                verdict = "TRUE" if unhex(c["Expected"])[-1] == 1 else "REJECT"
                h.case(f"geth {n}", verdict, pairs=convert(unhex(c["Input"])))
            for n, c in fail.items():
                data = unhex(c["Input"])
                if data and len(data) % 384 == 0:
                    pairs = convert(data)
                    if pairs is not None:
                        h.case(f"geth {n}", "REJECT", pairs=pairs)
        else:
            width = 64 if kind == "MapG1" else 128
            out_size = 96 if kind == "MapG1" else 192
            h = Header(function, [("fp", "bytes"), ("out", "bytes")],
                       f"go-ethereum {name}.json and fail-{name}.json, execution-specs EIP-2537 vectors")
            for n, c in take(valid, 5):
                h.case(f"geth {n}", "OK", fp=fps(unhex(c["Input"])), out=fps(unhex(c["Expected"])))
            for n, c in fail.items():
                data = unhex(c["Input"])
                if len(data) == width and fps(data) is not None:
                    h.case(f"geth {n}", "EFAIL", fp=fps(data), out=bytes(out_size))
        add_eest_bls(h, function, kind)
        h.write()


def gen_p256():
    h = Header("zkvm_secp256r1_verify", [("msg", "bytes"), ("sig", "bytes"), ("pubkey", "bytes")],
               "go-ethereum p256Verify.json (EIP-7212, Wycheproof-derived)")
    cases = geth("p256Verify")
    valid = take(cases, 4, lambda c: unhex(c["Expected"]) != b"")
    invalid = take(cases, 4, lambda c: unhex(c["Expected"]) == b"" and len(unhex(c["Input"])) == 160)
    for n, c in valid + invalid:
        data = unhex(c["Input"])
        expect = "TRUE" if unhex(c["Expected"]) else "REJECT"
        label = n.split(": ", 1)[-1] if ": " in n else n
        h.case(f"geth {label}", expect, msg=data[:32], sig=data[32:96], pubkey=data[96:160])
    h.write()


def main():
    gen_hashes()
    gen_secp256k1()
    gen_modexp()
    gen_bn254()
    gen_blake2f()
    gen_kzg()
    gen_bls()
    gen_p256()


if __name__ == "__main__":
    main()
