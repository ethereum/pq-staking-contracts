// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {RegistrationQueue} from "./RegistrationQueue.sol";

/// @title PQValidatorRegistration
/// @notice Validator registration system contract per EIP-8413, with an EIP-7002-style fee and
///         queue. See `RegistrationQueue` for the request format and `SystemRequestQueue` for
///         the fee and system call.
/// @dev Identical code to `PQBuilderRegistration`; the consensus layer tells the roles apart by
///      contract address (and EIP-7685 request type).
contract PQValidatorRegistration is RegistrationQueue {}
