// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {RegistrationQueue} from "./RegistrationQueue.sol";

/// @title PQBuilderRegistration
/// @notice Builder registration system contract. Builders create stake through `PQStaking` like
///         validators, then register here instead of in `PQValidatorRegistration`.
/// @dev Identical code to `PQValidatorRegistration`; the consensus layer tells the roles apart by
///      contract address (and EIP-7685 request type).
contract PQBuilderRegistration is RegistrationQueue {}
