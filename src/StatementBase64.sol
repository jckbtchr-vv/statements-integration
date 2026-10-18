// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Base64 (RFC 4648, padded), byte for byte what OpenZeppelin's Base64.encode gives, 24
///         input bytes to 32 characters at a time: each three-byte group moves into its own
///         four-byte lane, splits into four sextets (one to a byte), and all 32 sextets become
///         characters at once by byte-wise arithmetic. No table, no store per character.
library StatementBase64 {
    /// @notice `data` in Base64, as a new string.
    function encode(bytes memory data) internal pure returns (string memory result) {
        uint256 length = (data.length + 2) / 3 * 4;
        uint256 at;
        assembly ("memory-safe") {
            result := mload(0x40)
            at := add(result, 32)
            // write's last word can run up to 28 bytes past the end: 32 spare.
            mstore(0x40, and(add(add(at, length), 63), not(31)))
        }
        write(at, data);
        assembly ("memory-safe") {
            mstore(result, length)
        }
    }

    /// @notice Writes `data` in Base64 at memory address `at` and returns the address just past it.
    ///         Up to 28 bytes past that may be overwritten too: the caller leaves room, or writes
    ///         over them next. May read, but ignores, up to 31 bytes past `data`'s end.
    function write(uint256 at, bytes memory data) internal pure returns (uint256 end) {
        assembly ("memory-safe") {
            // 24 bytes (the word's first 24; the rest are ignored) to 32 characters.
            function chunk(w) -> r {
                // Groups 4-7 to bytes 16-27, then 2-3 (and 6-7) two bytes on, then each group to
                // the low three bytes of its four-byte lane.
                w := or(
                    and(w, 0xffffffffffffffffffffffff0000000000000000000000000000000000000000),
                    and(shr(32, w), 0x00000000000000000000000000000000ffffffffffffffffffffffff00000000)
                )
                w := or(
                    and(w, 0xffffffffffff00000000000000000000ffffffffffff00000000000000000000),
                    and(shr(16, w), 0x0000000000000000ffffffffffff00000000000000000000ffffffffffff0000)
                )
                w := or(
                    and(shr(8, w), 0x00ffffff0000000000ffffff0000000000ffffff0000000000ffffff00000000),
                    and(shr(16, w), 0x0000000000ffffff0000000000ffffff0000000000ffffff0000000000ffffff)
                )
                // A lane's 24 bits to four sextets, one in each byte.
                r := or(
                    or(
                        and(shl(6, w), 0x3f0000003f0000003f0000003f0000003f0000003f0000003f0000003f000000),
                        and(shl(4, w), 0x003f0000003f0000003f0000003f0000003f0000003f0000003f0000003f0000)
                    ),
                    or(
                        and(shl(2, w), 0x00003f0000003f0000003f0000003f0000003f0000003f0000003f0000003f00),
                        and(w, 0x0000003f0000003f0000003f0000003f0000003f0000003f0000003f0000003f)
                    )
                )
                // Sextet v to its character: v + 65 ('A'), + 6 from 26 ('a'), - 75 from 52 ('0'),
                // - 15 from 62 ('+'), + 3 at 63 ('/'). "v >= k" is bit 7 of v + 128 - k; no byte
                // carries or borrows into the next.
                let h := 0x8080808080808080808080808080808080808080808080808080808080808080
                let a := add(r, 0x4141414141414141414141414141414141414141414141414141414141414141)
                r := add(
                    add(a, mul(shr(7, and(add(r, 0x6666666666666666666666666666666666666666666666666666666666666666), h)), 6)),
                    mul(shr(7, and(a, h)), 3)
                )
                r := sub(
                    r,
                    add(
                        mul(shr(7, and(add(a, 0x0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b), h)), 75),
                        mul(shr(7, and(add(a, 0x0101010101010101010101010101010101010101010101010101010101010101), h)), 15)
                    )
                )
            }
            let n := mload(data)
            let src := add(data, 32)
            end := add(at, mul(div(add(n, 2), 3), 4))
            let whole := add(src, mul(div(n, 24), 24))
            for {} lt(src, whole) {} {
                mstore(at, chunk(mload(src)))
                src := add(src, 24)
                at := add(at, 32)
            }
            let rest := sub(add(add(data, 32), n), src)
            // The last 1-23 bytes, the rest of the word cleared.
            if rest { mstore(at, chunk(and(mload(src), not(shr(shl(3, rest), not(0)))))) }
            switch mod(n, 3)
            case 1 {
                mstore8(sub(end, 2), 0x3d)
                mstore8(sub(end, 1), 0x3d)
            }
            case 2 { mstore8(sub(end, 1), 0x3d) }
        }
    }
}
