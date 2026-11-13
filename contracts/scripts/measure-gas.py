#!/usr/bin/env python3
"""Measures the gas of the proof of possession on Amsterdam, as Foundry implements it, and prints every number.

It first runs the forge snapshot test for verify alone. Then, on anvil, it sends an EIP-8483 validator add with and
without the proof in each scenario, and checks each transaction's gasUsed against its intrinsic gas, calldata floor and
traced execution. Last, it splits a verify into its KECCAK256s.

The adds go to three contracts: the EIP's bytecode, this repository's PQValidatorRegistration, and the same contract
with the check skipped (test/helpers/Unchecked.sol). The last two take the same calldata, so the difference between
them is what checking the proof costs.

Run it from anywhere, with forge and anvil on the PATH: `python3 contracts/scripts/measure-gas.py`.
"""

import json
import os
import socket
import subprocess
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUNTIME = open(os.path.join(ROOT, "test/vectors/eip8483/validator.hex")).read().strip()
VECTORS = json.load(open(os.path.join(ROOT, "test/vectors/leanxmss_pop.json")))
PROOF = VECTORS["proofs"][0]
# 32 bytes standing in for the VRF data, the second half of a validator's pq_data.
VRF_DATA = "ee" * 32
# The address of each contract. EIP-8483 hasn't chosen the predeploy addresses yet.
TARGETS = {
    "add": "0x0000000000000000000000000000000000008483",
    "unchecked": "0x000000000000000000000000000000000000C000",
    "proof": "0x000000000000000000000000000000000000C001",
}
PATHS = list(TARGETS)
HARNESS = "0x000000000000000000000000000000000000B000"
SCENARIOS = {
    "S1": "the first request ever",
    "S2": "the first request of a block, on a queue used before",
    "S3": "a later request in the same block",
}
GWEI = [1, 5, 20]
# Calldata gas per zero and nonzero byte: the standard cost, and the floor (EIP-7623, raised in Amsterdam).
CALLDATA, CALLDATA_FLOOR = (4, 16), (64, 64)
TRACE = {"disableStack": True, "disableMemory": True, "disableStorage": True}

SLOT_EXCESS, SLOT_COUNT, SLOT_HEAD, SLOT_TAIL, SLOT_LAST_BLOCK, QUEUE_OFFSET = range(6)
SLOTS_PER_ITEM = 5
INPUT_SIZE = 112


def word(n):
    return "0x" + n.to_bytes(32, "big").hex()


class Anvil:
    def __init__(self):
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            self.port = s.getsockname()[1]
        self.proc = subprocess.Popen(
            ["anvil", "--hardfork", "amsterdam", "--port", str(self.port), "--steps-tracing"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        for _ in range(100):
            try:
                self.sender = self.rpc("eth_accounts")[0]
                return
            except OSError:
                time.sleep(0.1)
        raise RuntimeError("anvil did not start")

    def close(self):
        self.proc.terminate()
        self.proc.wait()

    def rpc(self, method, *params):
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}", body, {"Content-Type": "application/json"})
        res = json.load(urllib.request.urlopen(req))
        if "error" in res:
            raise RuntimeError(f"{method}: {res['error']}")
        return res["result"]

    def storage(self, address, slot):
        return int(self.rpc("eth_getStorageAt", address, hex(slot), "latest"), 16)

    def fee(self, target):
        """Calls the fee getter, which is the same in the three contracts."""
        return int(self.rpc("eth_call", {"to": target, "data": "0x"}, "latest"), 16)

    def send(self, to, data, value):
        """Sends a transaction and returns its hash, without waiting for its receipt."""
        tx = {"from": self.sender, "to": to, "data": data, "value": hex(value), "gas": hex(3_000_000)}
        return self.rpc("eth_sendTransaction", tx)

    def receipt(self, tx, status=1):
        for _ in range(100):
            r = self.rpc("eth_getTransactionReceipt", tx)
            if r is not None:
                assert int(r["status"], 16) == status, r
                return r
            time.sleep(0.05)
        raise RuntimeError(f"{tx} was not mined")


def scenarios(node, target, data):
    """Sends the adds of S1, S2 and S3 to `target`, whose storage starts empty, and returns their receipts.

    S1 is the first request ever. S2 is the first request of a block on a queue that was used before, and S3 is the
    request after it in the same block, so both land in one block.
    """
    s1 = node.receipt(node.send(target, data, node.fee(target)))
    check_landed(node, target, data, [s1], 1)
    head = int(node.rpc("eth_blockNumber"), 16)
    slots = {SLOT_EXCESS: 0, SLOT_COUNT: 3, SLOT_HEAD: 0, SLOT_TAIL: 0, SLOT_LAST_BLOCK: head}
    for slot in range(QUEUE_OFFSET, QUEUE_OFFSET + 2 * SLOTS_PER_ITEM):
        slots[slot] = int("ee" * 32, 16)
    for slot, value in slots.items():
        node.rpc("anvil_setStorageAt", target, word(slot), word(value))
    node.rpc("evm_setAutomine", False)
    fee = node.fee(target)
    txs = [node.send(target, data, fee) for _ in range(2)]
    node.rpc("evm_mine")
    node.rpc("evm_setAutomine", True)
    s2, s3 = [node.receipt(tx) for tx in txs]
    assert s2["blockNumber"] == s3["blockNumber"] and int(s3["transactionIndex"], 16) == 1
    check_landed(node, target, data, [s2, s3], 2)
    return {"S1": s1, "S2": s2, "S3": s3}


def check_landed(node, target, data, receipts, tail):
    """Checks that each add logged its 132-byte record from `target`, without the signature, and moved the tail."""
    record = "0x" + node.sender[2:].lower() + data[2 : 2 + 2 * INPUT_SIZE]
    for r in receipts:
        # EIP-7708 also logs the fee's transfer.
        [log] = [log for log in r["logs"] if log["address"].lower() == target.lower()]
        assert log["topics"] == [] and log["data"] == record, log
    assert node.storage(target, SLOT_TAIL) == tail


def check_tampered(node, target, data):
    """Checks that an add whose signature has its last byte flipped reverts, without changing a slot an add writes."""
    data = data[:-2] + f"{int(data[-2:], 16) ^ 1:02x}"
    slots = range(QUEUE_OFFSET + 3 * SLOTS_PER_ITEM)
    before = [node.storage(target, slot) for slot in slots]
    r = node.receipt(node.send(target, data, node.fee(target)), status=0)
    assert [node.storage(target, slot) for slot in slots] == before
    return r, data


def base_gas(node):
    """The base intrinsic gas of a call without value and with 1 wei: the gasUsed of an empty call to a STOP."""
    stop = "0x000000000000000000000000000000000000BEEF"
    node.rpc("anvil_setCode", stop, "0x00")
    return [int(node.receipt(node.send(stop, "0x", value))["gasUsed"], 16) for value in (0, 1)]


def execution(node, tx, stack=False):
    """Returns the gas the transaction's execution used, read from its trace, and the trace's steps."""
    steps = node.rpc("debug_traceTransaction", tx, {**TRACE, "disableStack": not stack})["structLogs"]
    first, last = steps[0], steps[-1]
    # Below EIP-7825's transaction gas cap, EIP-8037 state gas is charged from the regular gas counter.
    assert first.get("stateGasReservoir", 0) == last.get("stateGasReservoir", 0) == 0
    assert last["refund"] == 0
    return first["gas"] - (last["gas"] - last["gasCost"]), steps


def breakdown(node, base, receipt, data):
    """Splits a transaction's gasUsed into intrinsic gas and execution, or the calldata floor, and checks the sum."""
    b = bytes.fromhex(data[2:])
    zeros, nonzeros = b.count(0), len(b) - b.count(0)
    (sz, snz), (fz, fnz) = CALLDATA, CALLDATA_FLOOR
    intrinsic = base + sz * zeros + snz * nonzeros
    floor = base + fz * zeros + fnz * nonzeros
    exe, _ = execution(node, receipt["transactionHash"])
    gas_used = int(receipt["gasUsed"], 16)
    assert gas_used == max(intrinsic + exe, floor), (gas_used, intrinsic, exe, floor)
    pays = "floor" if floor > intrinsic + exe else "standard"
    return dict(
        hash=receipt["transactionHash"],
        zeros=zeros,
        nonzeros=nonzeros,
        intrinsic=intrinsic,
        floor=floor,
        execution=exe,
        gas=gas_used,
        pays=pays,
    )


def artifact(source, contract):
    with open(os.path.join(ROOT, f"out/{source}/{contract}.json")) as f:
        return json.load(f)


def verify_breakdown(node, base):
    """Sends a transaction calling LeanXmss's verify on the proof, and splits its execution into the KECCAK256
    opcodes, grouped by input length, and everything else."""
    h = artifact("LeanXmss.t.sol", "LeanXmssHarness")
    node.rpc("anvil_setCode", HARNESS, h["deployedBytecode"]["object"])
    sig = PROOF["signature"][2:]
    data = "0x" + h["methodIdentifiers"]["verify(bytes32,bytes32,bytes)"] + PROOF["xmssPubkey"][2:]
    data += PROOF["message"][2:] + word(0x60)[2:] + word(len(sig) // 2)[2:] + sig + "0" * (-len(sig) % 64)
    r = node.receipt(node.send(HARNESS, data, 0))
    tx = breakdown(node, base, r, data)
    exe, steps = execution(node, r["transactionHash"], stack=True)
    assert node.rpc("debug_traceTransaction", r["transactionHash"], TRACE)["returnValue"].endswith("1")
    keccak = {}
    for step in steps:
        if step["op"] == "KECCAK256":
            # The trace lists the stack bottom first, so the offset is last and the length second to last.
            n, g = keccak.get(int(step["stack"][-2], 16), (0, 0))
            keccak[int(step["stack"][-2], 16)] = (n + 1, g + step["gasCost"])
    return dict(tx=tx, keccak=keccak, rest=exe - sum(g for _, g in keccak.values()))


def snapshots():
    """Runs the verify gas test and returns, per kind, the min and max of its snapshot over the valid vectors."""
    cmd = ["forge", "test", "--root", ROOT, "--isolate", "--match-contract", "VerifyGasTest"]
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    with open(os.path.join(ROOT, "snapshots/verify.json")) as f:
        snap = json.load(f)
    out = {}
    for name, value in snap.items():
        kind, _ = name.split()
        out.setdefault(kind, []).append(int(value))
    return {kind: (min(values), max(values)) for kind, values in out.items()}


def main():
    subprocess.run(["forge", "build", "--root", ROOT], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    snaps = snapshots()
    print("verify alone, min and max over the 4 valid vectors")
    for kind in ["transaction", "execution"]:
        print(f"{kind:16}{'%d to %d' % snaps[kind]:>20}")
    print()

    assert len(PROOF["blsPubkey"]) == 2 + 2 * 48 and PROOF["leafIndex"] == 0
    add = "0x" + PROOF["blsPubkey"][2:] + PROOF["xmssPubkey"][2:] + VRF_DATA
    assert len(add) == 2 + 2 * INPUT_SIZE
    request = add + PROOF["signature"][2:]
    code = {
        "add": RUNTIME,
        "unchecked": artifact("Unchecked.sol", "UncheckedValidatorRegistration")["deployedBytecode"]["object"],
        "proof": artifact("PQValidatorRegistration.sol", "PQValidatorRegistration")["deployedBytecode"]["object"],
    }
    rows = {}
    node = Anvil()
    try:
        assert int(node.rpc("eth_chainId"), 16) == VECTORS["chainId"]
        base_no_value, base_value = base_gas(node)
        for path, target in TARGETS.items():
            node.rpc("anvil_setCode", target, code[path])
            data = add if path == "add" else request
            for scenario, r in scenarios(node, target, data).items():
                # Every add pays a 1 wei fee, so it pays the base of a call with value.
                rows[path, scenario] = breakdown(node, base_value, r, data)
        breakdown(node, base_value, *check_tampered(node, TARGETS["proof"], request))
        v = verify_breakdown(node, base_no_value)
    finally:
        node.close()

    print(f"base {base_value} for a call with 1 wei ({base_no_value} without value)")
    print(f"{'':14}{'zeros':>6}{'nonzero':>8}{'intrinsic':>10}{'floor':>8}{'execution':>10}{'gasUsed':>9}  pays")
    for path in PATHS:
        for scenario in SCENARIOS:
            r = rows[path, scenario]
            print(
                f"{path:10}{scenario:4}{r['zeros']:>6}{r['nonzeros']:>8}{r['intrinsic']:>10}{r['floor']:>8}"
                f"{r['execution']:>10}{r['gas']:>9}  {r['pays']}"
            )
    print()

    print("LeanXmss's verify of the proof as a transaction: execution, its KECCAK256 opcodes by input length, the rest")
    print(f"{'gasUsed':22}{v['tx']['gas']:>10}")
    print(f"{'pays':22}{v['tx']['pays']:>10}")
    print(f"{'execution':22}{v['tx']['execution']:>10}")
    total = sum(n for n, _ in v["keccak"].values())
    print(f"{f'KECCAK256 x{total}':22}{sum(g for _, g in v['keccak'].values()):>10}")
    for size, (n, g) in sorted(v["keccak"].items()):
        print(f"{f'  {size} bytes x{n}':22}{g:>10}")
    print(f"{'everything else':22}{v['rest']:>10}")

    for scenario, title in SCENARIOS.items():
        print()
        print(f"{scenario}, {title}")
        gas = {p: rows[p, scenario]["gas"] for p in PATHS}
        exe = {p: rows[p, scenario]["execution"] for p in PATHS}
        lines = [
            ("EIP's add, without the proof", gas["add"]),
            ("this contract, the proof unchecked", gas["unchecked"]),
            ("this contract, the proof checked", gas["proof"]),
            ("proof - add", gas["proof"] - gas["add"]),
            ("unchecked - add", gas["unchecked"] - gas["add"]),
            ("unchecked - add in execution", exe["unchecked"] - exe["add"]),
            ("proof - unchecked", gas["proof"] - gas["unchecked"]),
            ("proof - unchecked in execution", exe["proof"] - exe["unchecked"]),
        ]
        for label, value in lines:
            print(f"{label:40}{value:>12}")
        for path, label in [("add", "without"), ("proof", "with")]:
            for gwei in GWEI:
                print(f"{f'ETH {label} the proof at {gwei} gwei':40}{gas[path] * gwei / 1e9:>12.6f}")


if __name__ == "__main__":
    main()
