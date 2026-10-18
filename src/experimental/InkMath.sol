// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Experimental: palette weights measure the stored union of occupied CMYK plate bits.
/// They do not recover how many times an overlapping mark was printed.
library InkMath {
    uint256 private constant LANES = 0x1111111111111111111111111111111111111111111111111111111111111111;
    uint256 private constant BYTES = 0x0101010101010101010101010101010101010101010101010101010101010101;
    error EmptyInk();
    function sum(uint256[4] memory v) internal pure returns (uint256) {return v[0]+v[1]+v[2]+v[3];}
    function count(uint256[240] memory words) internal pure returns (uint256[4] memory weights) {
        for (uint256 i; i < 240; ++i) {
            uint256 word = i % 3 == 2 ? words[i] & type(uint64).max : words[i];
            for (uint256 c; c < 4; ++c) {
                uint256 lanes = (word >> c) & LANES;
                lanes = (lanes & BYTES) + ((lanes >> 4) & BYTES);
                unchecked {weights[c] += (lanes * BYTES) >> 248;}
            }
        }
    }
    /// @notice Largest-remainder allocation. Ties go C, M, Y, K. No units are created or lost.
    function split(uint256 amount, uint256[4] memory weights) internal pure returns (uint256[4] memory out) {
        uint256 denominator = sum(weights);
        if (denominator == 0) revert EmptyInk();
        uint256[4] memory remainders;
        uint256 allocated;
        for (uint256 c; c < 4; ++c) {
            out[c] = Math.mulDiv(amount, weights[c], denominator);
            remainders[c] = mulmod(amount, weights[c], denominator);
            allocated += out[c];
        }
        for (uint256 left = amount - allocated; left > 0; --left) {
            uint256 best;
            for (uint256 c = 1; c < 4; ++c) if (remainders[c] > remainders[best]) best = c;
            ++out[best];
            remainders[best] = 0;
        }
    }
}
