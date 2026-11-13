// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {PQValidatorRegistration} from "../../src/PQValidatorRegistration.sol";

/// The validator contract without the proof-of-possession check, for the gas measurement in
/// scripts/measure-gas.py. Its requests still carry the signature, so its gas difference with
/// `PQValidatorRegistration` is the cost of the check.
contract UncheckedValidatorRegistration is PQValidatorRegistration {
    function _checkProofOfPossession(bytes calldata) internal pure override {}
}
