// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {MutualFunToken} from "../src/MutualFunToken.sol";

/// @title Deployment script for The mutual fun (TMF)
/// @notice Reviewable reference only. The IdentityMD launch deploys the token from its attested
///         creation code through the ProjectFactory; this script is for local forks and tests.
///         The constructor takes no arguments, so there is no configuration to read.
contract DeployMutualFunToken is Script {
    /// @notice Deploys the token. Whoever broadcasts receives the whole supply.
    function deploy() public returns (MutualFunToken token) {
        token = new MutualFunToken();
    }

    /// @notice Entry point for `forge script`. Broadcasts a single deployment.
    function run() external returns (MutualFunToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
