// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LineageWithdrawals} from "./LineageWithdrawals.sol";

/// @notice Conversion-only Balance. No auction or liquidity custody. Public conversion and transfers share one timestamp.
/// The creator finalizes the round supply from their own surrendered artwork once;
/// then every holder can surrender and transfer under the same permanent rules.
contract ConversionLineageWithdrawals is LineageWithdrawals {
    uint64 public constant opensAt = 1792506000; // October 20, 2026, 10:20 AM America/New_York (EDT).
    address public immutable retirementFunder;
    uint256 public constant launchSupply = 53_750_000 ether;
    uint256 public constant launchRetirement = maxSupply - launchSupply;
    uint256 public totalRetired;
    error ConversionNotOpen(uint64 timestamp);
    error InvalidRetirementFunder();
    error LaunchSupplyNotFinalized();
    error InvalidLaunchRetirement();
    event LaunchSupplyRetired(address indexed funder, uint256 amount, uint256 remainingSupply);

    constructor(address source, uint8 format, address funder) LineageWithdrawals(source, format) {
        if (funder == address(0) || funder == address(this)) revert InvalidRetirementFunder();
        retirementFunder = funder;
    }

    function retireLaunchSupply() external nonReentrant {
        if (msg.sender != retirementFunder || totalRetired != 0) revert InvalidLaunchRetirement();
        totalRetired = launchRetirement;
        _burn(msg.sender, launchRetirement);
        emit LaunchSupplyRetired(msg.sender, launchRetirement, totalSupply());
    }

    function _checkWithdrawal() internal view override {
        // Creator setup can release only into its own wallet before retirement.
        if (block.timestamp < opensAt && !(msg.sender == retirementFunder && totalRetired == 0)) revert ConversionNotOpen(opensAt);
        if (totalRetired != launchRetirement && msg.sender != retirementFunder) revert LaunchSupplyNotFinalized();
    }

    function _update(address from, address to, uint256 value) internal override {
        bool movement = from != address(0) && from != address(this) && value != 0 && from != to;
        if (movement && totalRetired != launchRetirement) revert LaunchSupplyNotFinalized();
        if (movement && to != address(0) && block.timestamp < opensAt) revert ConversionNotOpen(opensAt);
        super._update(from, to, value);
    }
}
