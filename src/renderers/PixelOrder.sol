// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Cosmetic, deterministic pixel shuffle; not security randomness.
/// @dev Mirrors pixel-order.mjs. Permuted ranks preserve exact color counts.
library PixelOrder {
    function ranks(uint256 count, bytes memory label) internal pure returns (uint256[] memory order) {
        order = new uint256[](count);
        for (uint256 i; i < count; ++i) order[i] = i;
        uint256 state = 2166136261;
        for (uint256 i; i < label.length; ++i) state = ((state ^ uint8(label[i])) * 16777619) & 0xffffffff;
        if (state == 0) state = 0x9e3779b9;
        for (uint256 remaining = count; remaining > 1; --remaining) {
            state ^= (state << 13) & 0xffffffff;
            state ^= state >> 17;
            state ^= (state << 5) & 0xffffffff;
            uint256 j = state % remaining;
            (order[remaining - 1], order[j]) = (order[j], order[remaining - 1]);
        }
    }
}
