// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LineageWithdrawals} from "./LineageWithdrawals.sol";

/// @notice Experimental Ethereum launch gate with one fixed creator retirement.
/// @dev All values are fixed at deployment. Only the named funding routes can move
/// tokens before opening, after the funder has finalized supply. Other holders
/// cannot surrender until then. No party can change the opening block or amount.
/// Not suitable for chains whose CCA uses a different block-number clock.
contract AuctionLineageWithdrawals is LineageWithdrawals {
    uint64 public immutable transfersOpenBlock;
    address public immutable auctionFunder;
    address public immutable auctionCustodian;
    address public immutable liquidityCustodian;
    uint256 public constant launchSupply = 53_750_000 ether;
    uint256 public constant launchRetirement = maxSupply - launchSupply;
    uint256 public totalRetired;
    error InvalidAuctionGate();
    error AuctionTransfersLocked(uint64 opensAt);
    error LaunchSupplyNotFinalized();
    error InvalidLaunchRetirement();

    event LaunchSupplyRetired(address indexed funder, uint256 amount, uint256 remainingSupply);

    constructor(address source, uint8 format, uint64 opensAt, address funder, address custodian, address liquidity)
        LineageWithdrawals(source, format)
    {
        if (opensAt <= block.number || funder == address(0) || custodian == address(0)
            || liquidity == address(0) || funder == liquidity
            || funder == custodian || funder == address(this) || custodian == address(this)
            || liquidity == address(this)) {
            revert InvalidAuctionGate();
        }
        transfersOpenBlock = opensAt;
        auctionFunder = funder;
        auctionCustodian = custodian;
        liquidityCustodian = liquidity;
    }

    /// @notice Retire exactly 2,386.7072 of the funder's already released tokens.
    /// Callable once, by the immutable funder only. Source receipts, unreleased
    /// entitlement and every other holder's 1:1 conversion remain unchanged.
    /// No deadline: a delayed setup can finalize rather than strand the funder.
    function retireLaunchSupply() external nonReentrant {
        if (msg.sender != auctionFunder || totalRetired != 0) revert InvalidLaunchRetirement();
        totalRetired = launchRetirement;
        _burn(msg.sender, launchRetirement);
        emit LaunchSupplyRetired(msg.sender, launchRetirement, totalSupply());
    }

    function _checkWithdrawal() internal view override {
        if (totalRetired != launchRetirement && msg.sender != auctionFunder) revert LaunchSupplyNotFinalized();
    }

    function _update(address from, address to, uint256 value) internal override {
        // The base constructor mints the fixed reserve. There is no subsequent mint
        // entry point. Only the base withdraw function can send from that reserve.
        bool movement = from != address(0) && from != address(this) && value != 0 && from != to;
        if (movement && totalRetired != launchRetirement) revert LaunchSupplyNotFinalized();
        // Only retireLaunchSupply can reach the internal burn path.
        if (movement && to != address(0)
            && block.number < transfersOpenBlock
            && !(from == auctionFunder && (to == auctionCustodian || to == liquidityCustodian))) {
            revert AuctionTransfersLocked(transfersOpenBlock);
        }
        super._update(from, to, value);
    }
}
