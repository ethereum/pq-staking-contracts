module

import LeanXmssFv
import EthLib.Base.Hex
import EthLib.Execution.Transactions.Process
import Lean.Data.Json

/-!
# The bytecode on EthLib's EVM, over the vectors

Runs the runtime bytecode in `LeanXmssFv.Code` on EthLib's interpreter, compiled, as calls at
Glamsterdam with that fork's gas meter, which is where the forge tests run:

- `LeanXmssHarness` over EthLib's `verify` and `signature_index` cases, through its ABI.
- `PQValidatorRegistration` and `PQBuilderRegistration` over the proofs of possession of
  `leanxmss_pop.json`, as requests that pay the fee the contract asks for.

Each call starts from a state with the contract's code and a caller with ether. No theorem rests
on this test. It shows that EthLib's EVM runs the code as revm does, on the same cases, before
any proof is written.

Run it as `lake exe vectors`, optionally followed by the repository root, which is `..` by
default. It prints one line per family and the cases that disagree, and fails if any does.
-/

open EthLib EthLib.Base EthLib.Execution EthLib.Execution.Evm EthLib.Execution.State
open EthLib.Execution.Transactions (processMessageCall CallOutput)
open LeanXmssFv

namespace Vectors

/-! ## Bytes -/

/-- The bytes of a hex string, with or without `0x`, or none for a malformed string. -/
def hexBytes (text : String) : Option ByteArray :=
  let chars := text.toList
  Base.hexBytes? (if chars.take 2 == ['0', 'x'] then chars.drop 2 else chars)

/-- The `n` bytes of `x`, big-endian, keeping its lowest `n` bytes. -/
def beBytes (n x : Nat) : ByteArray :=
  ⟨Array.ofFn (n := n) fun i => UInt8.ofNat (x >>> (8 * (n - 1 - i.val)))⟩

/-- A 32-byte word. -/
def word (x : Nat) : ByteArray := beBytes 32 x

/-- The number that bytes hold, big-endian. -/
def toNat (bytes : ByteArray) : Nat := bytes.foldl (fun acc b => acc * 256 + b.toNat) 0

/-- `bytes` followed by zeros up to a multiple of 32 bytes, as the ABI pads a `bytes`. -/
def pad32 (bytes : ByteArray) : ByteArray :=
  bytes ++ ⟨Array.replicate ((32 - bytes.size % 32) % 32) 0⟩

/-- The address whose 20 bytes hold `x`. -/
def addressOf (x : Nat) : Address := Vector.ofFn fun i : Fin 20 => UInt8.ofNat (x >>> (8 * (19 - i.val)))

def sameBytes (a b : ByteArray) : Bool := a.data == b.data

/-! ## A call -/

/-- The fork of the calls. -/
abbrev FORK : Fork := .glamsterdam

/-- The account that holds the code. -/
def CONTRACT : Address := addressOf 0xc0de

/-- The account that calls it. -/
def CALLER : Address := addressOf 0xca11

/-- The execution gas of a call, far more than any of them takes. -/
def GAS : Nat := 30000000

/-- The block of every call, on the chain `chainId`. -/
def blockEnv (chainId : UInt64) : BlockEnvironment FORK where
  chainId := chainId
  coinbase := addressOf 0
  number := 1
  gasLimit := 60000000
  timestamp := 12
  difficulty := 0
  blockHashes := []
  baseFeePerGas := fun _ => 0
  prevRandao := fun _ => Vector.replicate 32 0
  excessBlobGas := fun _ => 0
  parentBeaconBlockRoot := fun _ => Vector.replicate 32 0
  slotNumber := fun _ => 1

/-- The state before a call: the contract with `code` and empty storage, and a caller with one
ether. -/
def preState (code : ByteArray) : TransactionState :=
  let codeHash := Cryptography.Hash.Keccak.keccak256 code
  .ofBlock
    { preState :=
        { accounts := (∅ : Std.ExtTreeMap Address Account)
            |>.insert CONTRACT ⟨1, 0, codeHash⟩
            |>.insert CALLER ⟨0, BitVec.ofNat 256 (10 ^ 18), EMPTY_CODE_HASH⟩
          storage := ∅
          code := (∅ : Std.ExtTreeMap Hash32 ByteArray).insert codeHash code }
      accountWrites := ∅
      storageWrites := ∅
      codeWrites := ∅
      storageClears := ∅ }

/-- A call from `CALLER` to `CONTRACT` with the data `data` and the value `value`, at Glamsterdam,
with the meter of EIP-8037. The message's code is read from the state. -/
def call (code : ByteArray) (chainId : UInt64) (data : ByteArray) (value : Nat := 0) :
    Except EvmError CallOutput :=
  let message : Message FORK :=
    { blockEnv := blockEnv chainId
      txEnv := { origin := CALLER, gasPrice := 0, blobVersionedHashes := fun _ => [] }
      caller := CALLER
      target := some CONTRACT
      currentTarget := CONTRACT
      gas := GAS
      value := BitVec.ofNat 256 value
      data := data
      codeAddress := some CONTRACT
      code := .empty
      depth := 0
      shouldTransferValue := true
      isStatic := false
      disablePrecompiles := false }
  processMessageCall (Meter := StateGasMeter) chainId.toNat message (preState code) Substate.empty

/-- What a call gives: its output when it succeeds, or none when it reverts with no data. -/
def outcome (result : Except EvmError CallOutput) : Option (Option ByteArray) :=
  match result with
  | .ok out =>
    match out.error with
    | none => some (some out.output)
    | some .revert => if out.output.size = 0 then some none else none
    | some _ => none
  | .error _ => none

/-! ## The harness -/

/-- The selector of an ABI function. -/
def selector (signature : String) : ByteArray :=
  (Cryptography.Hash.Keccak.keccak256 signature.toUTF8).toArray.extract 0 4 |> (⟨·⟩)

/-- The ABI call `verify(publicKey, message, signature)`. -/
def verifyData (publicKey message signature : ByteArray) : ByteArray :=
  selector "verify(bytes32,bytes32,bytes)" ++ publicKey ++ message ++ word 0x60 ++
    word signature.size ++ pad32 signature

/-- The ABI call `signatureIndex(signature)`. -/
def signatureIndexData (signature : ByteArray) : ByteArray :=
  selector "signatureIndex(bytes)" ++ word 0x20 ++ word signature.size ++ pad32 signature

/-- The counts of one family: cases run, cases left out, cases that disagree, and their names. -/
structure Tally where
  run : Nat := 0
  skipped : Nat := 0
  failed : Array String := #[]

def Tally.add (t : Tally) (name : String) (ok : Bool) : Tally :=
  { t with run := t.run + 1, failed := if ok then t.failed else t.failed.push name }

/-- The value of the first line that starts with `key` and a colon, after leading spaces, with
quotes and spaces dropped. -/
def field (yaml key : String) : Option String :=
  let label := (key ++ ":").toList
  (yaml.splitOn "\n").findSome? fun line =>
    let line := line.toList.dropWhile (· = ' ')
    if line.take label.length == label then
      some (String.ofList ((line.drop label.length).filter fun c => c ≠ '\'' ∧ c ≠ ' '))
    else none

/-- The subdirectories of a directory, in name order. -/
def caseDirs (dir : System.FilePath) : IO (Array System.FilePath) := do
  let entries ← dir.readDir
  let dirs ← entries.filterM fun e => e.path.isDir
  return (dirs.map (·.path)).qsort (·.toString < ·.toString)

/-- EthLib's `verify` cases on the harness. `verify` takes a key and a message of 32 bytes, so the
two cases with a shorter one can't be passed, and those must expect a rejection. A rejected input
of another kind is a signature of the wrong length, for which `verify` returns false. -/
def verifyCases (root : System.FilePath) : IO Tally := do
  let mut tally : Tally := {}
  for case in ← caseDirs (root / "contracts/test/vectors/ethlib/xmss/verify") do
    let yaml ← IO.FS.readFile (case / "data.yaml")
    let name := case.fileName.getD case.toString
    let expected := field yaml "output" == some "true"
    match (field yaml "public_key").bind hexBytes, (field yaml "message").bind hexBytes,
        (field yaml "signature").bind hexBytes with
    | some publicKey, some message, some signature =>
      if publicKey.size = 32 ∧ message.size = 32 then
        let got := outcome (call Code.Harness.CODE 1 (verifyData publicKey message signature))
        tally := tally.add name (got.bind id |>.map (sameBytes · (word expected.toNat)) |>.getD false)
      else if expected then tally := tally.add name false
      else tally := { tally with skipped := tally.skipped + 1 }
    | _, _, _ => tally := tally.add name false
  return tally

/-- EthLib's `signature_index` cases on the harness. A rejected input reverts with no data. -/
def signatureIndexCases (root : System.FilePath) : IO Tally := do
  let mut tally : Tally := {}
  for case in ← caseDirs (root / "contracts/test/vectors/ethlib/xmss/signature_index") do
    let yaml ← IO.FS.readFile (case / "data.yaml")
    let name := case.fileName.getD case.toString
    let ok := match (field yaml "signature").bind hexBytes, field yaml "output" with
      | some signature, some output =>
        let got := outcome (call Code.Harness.CODE 1 (signatureIndexData signature))
        match output.toNat? with
        | some index => got.bind id |>.map (sameBytes · (word index)) |>.getD false
        | none => output == "null" && got == some none
      | _, _ => false
    tally := tally.add name ok
  return tally

/-! ## Proofs of possession -/

/-- A proof of possession of `leanxmss_pop.json`. -/
structure Proof where
  name : String
  blsPubkey : ByteArray
  xmssPubkey : ByteArray
  signature : ByteArray

def Proof.ofJson (name : String) (j : Lean.Json) : Except String Proof := do
  let bytes (key : String) : Except String ByteArray := do
    let text ← j.getObjValAs? String key
    (hexBytes text).elim (.error s!"{name}: {key} is not hex") .ok
  return ⟨name, ← bytes "blsPubkey", ← bytes "xmssPubkey", ← bytes "signature"⟩

/-- A registration contract: its code, and its input for a proof, before the signature. -/
structure Registration where
  name : String
  code : ByteArray
  input : Proof → ByteArray

/-- A validator's input: the BLS key, then `pq_data`, which is the XMSS key and 32 bytes of VRF
data that `M` doesn't bind. -/
def validator : Registration :=
  ⟨"PQValidatorRegistration", Code.Validator.CODE,
    fun p => p.blsPubkey ++ p.xmssPubkey ++ beBytes 32 0x5eed⟩

/-- A builder's input: the BLS key, then the XMSS key. -/
def builder : Registration :=
  ⟨"PQBuilderRegistration", Code.Builder.CODE, fun p => p.blsPubkey ++ p.xmssPubkey⟩

/-- Whether a request with the proof `p` gets the outcome it should: an accepted one returns no
data and logs the caller followed by the input, and a rejected one reverts with no data. It pays
the fee that a call with no data returns. -/
def request (r : Registration) (chainId : UInt64) (p : Proof) (accepted : Bool) : Bool :=
  match outcome (call r.code chainId .empty) with
  | some (some fee) =>
    let result := call r.code chainId (r.input p ++ p.signature) (toNat fee)
    match outcome result, result with
    | some (some output), .ok out =>
      accepted && output.size == 0 &&
        match out.logs.toList.filter (·.address == CONTRACT) with
        | [log] => log.topics.isEmpty &&
            sameBytes log.data (⟨CALLER.toArray⟩ ++ r.input p)
        | _ => false
    | some none, _ => !accepted
    | _, _ => false
  | _ => false

/-- The proofs of `leanxmss_pop.json` on a registration contract, on the file's chain. The three
proofs are accepted. The one at leaf 1 and the one of the message without the domain verify, and
are rejected. -/
def popCases (root : System.FilePath) (r : Registration) : IO Tally := do
  let text ← IO.FS.readFile (root / "contracts/test/vectors/leanxmss_pop.json")
  let parsed : Except String (Nat × Array Proof × Array Proof) := do
    let j ← Lean.Json.parse text
    let chainId ← j.getObjValAs? Nat "chainId"
    let proofs ← j.getObjValAs? (Array Lean.Json) "proofs"
    let accepted ← (proofs.zipIdx).mapM fun (p, i) => Proof.ofJson s!"proofs[{i}]" p
    let rejected ← #["wrongLeaf", "noDomain"].mapM fun key => do
      Proof.ofJson key (← j.getObjVal? key)
    return (chainId, accepted, rejected)
  match parsed with
  | .error e => return { failed := #[e] }
  | .ok (chainId, accepted, rejected) =>
    let mut tally : Tally := {}
    for p in accepted do
      tally := tally.add p.name (request r chainId.toUInt64 p true)
    for p in rejected do
      tally := tally.add p.name (request r chainId.toUInt64 p false)
    return tally

/-- Run one family, print its counts and its time, and say whether every case ran and agreed. -/
def report (name : String) (expected : Nat) (family : IO Tally) : IO Bool := do
  let start ← IO.monoMsNow
  let tally ← family
  let stop ← IO.monoMsNow
  let skipped := if tally.skipped = 0 then "" else s!", {tally.skipped} can't be passed"
  IO.println s!"{name}: {tally.run} cases{skipped}, {tally.failed.size} disagree, {stop - start} ms"
  for n in tally.failed do IO.println s!"  disagrees: {n}"
  return tally.failed.isEmpty && tally.run == expected

end Vectors

open Vectors in
public def main (args : List String) : IO UInt32 := do
  let root : System.FilePath := args.headD ".."
  let mut ok := true
  ok := (← report "verify (harness)" 38 (verifyCases root)) && ok
  ok := (← report "signature_index (harness)" 8 (signatureIndexCases root)) && ok
  ok := (← report "proofs of possession (validator)" 5 (popCases root validator)) && ok
  ok := (← report "proofs of possession (builder)" 5 (popCases root builder)) && ok
  return if ok then 0 else 1
