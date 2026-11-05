// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @title LaunchToken
/// @notice A plain token with its whole supply minted once, at creation. No owner, no tax, no pause,
/// no blocklist and no further mint.
contract LaunchToken is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 supply, address to) ERC20(name_, symbol_, 18) {
        _mint(to, supply);
    }
}
