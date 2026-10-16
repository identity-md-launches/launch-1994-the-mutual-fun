// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title The mutual fun (TMF)
/// @notice A fixed-supply ERC-20. The whole supply of 1,000,000,000 TMF (18 decimals) is minted
///         once to the deployer in the constructor. There is no owner, no further minting, no
///         pause, no blacklist, no fee on transfer and no upgrade path: after deployment the
///         contract is immutable and every holder controls only their own balance.
/// @dev The deployer is `msg.sender` of the constructor. At launch that is the IdentityMD
///      ProjectFactory, which distributes the supply (swarm share, pool seed, remainder) itself.
///      The Solidity identifier `MutualFunToken` is the launch's contract name; the token's own
///      name and symbol are returned by `name()` and `symbol()`.
contract MutualFunToken is ERC20 {
    /// @notice ERC-20 name of the token.
    string public constant TOKEN_NAME = "The mutual fun";

    /// @notice ERC-20 symbol of the token.
    string public constant TOKEN_SYMBOL = "TMF";

    /// @notice Number of decimals, the ERC-20 default.
    uint8 public constant TOKEN_DECIMALS = 18;

    /// @notice Total supply in whole tokens.
    uint256 public constant TOTAL_SUPPLY_TOKENS = 1_000_000_000;

    /// @notice Total supply in minor units (1,000,000,000 * 10^18).
    uint256 public constant TOTAL_SUPPLY = TOTAL_SUPPLY_TOKENS * 10 ** uint256(TOKEN_DECIMALS);

    /// @notice Mints the entire fixed supply to the deployer. Nothing can mint afterwards.
    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
