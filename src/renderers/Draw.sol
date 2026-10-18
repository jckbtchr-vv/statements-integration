// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice A growable-free SVG writer for the renderers: one preallocated buffer, no string
///         concatenation. Numbers are written as whole numbers, exactly as
///         script/statement-renderers.mjs writes them.
library Draw {
    struct Out {
        bytes b;
        uint256 n;
    }

    function init(uint256 capacity) internal pure returns (Out memory o) {
        o.b = new bytes(capacity);
    }

    function done(Out memory o) internal pure returns (string memory s) {
        bytes memory b = o.b;
        uint256 n = o.n;
        assembly ("memory-safe") {
            mstore(b, n)
        }
        s = string(b);
    }

    function str(Out memory o, bytes memory x) internal pure {
        uint256 n = o.n;
        uint256 len = x.length;
        require(n + len <= o.b.length, "SVG capacity");
        bytes memory b = o.b;
        assembly ("memory-safe") {
            mcopy(add(add(b, 32), n), add(x, 32), len)
        }
        o.n = n + len;
    }

    function ch(Out memory o, bytes1 c) internal pure {
        bytes memory b = o.b;
        uint256 n = o.n;
        assembly ("memory-safe") {
            if iszero(lt(n, mload(b))) {
                mstore(0, 0x08c379a0) // Error("SVG capacity")
                revert(0x1c, 4)
            }
            mstore8(add(add(b, 32), n), shr(248, c))
        }
        o.n = n + 1;
    }

    /// Whole number, decimal.
    function u(Out memory o, uint256 v) internal pure {
        bytes memory b = o.b;
        uint256 n = o.n;
        assembly ("memory-safe") {
            let digits := 1
            for { let t := v } gt(t, 9) { t := div(t, 10) } { digits := add(digits, 1) }
            if gt(add(n, digits), mload(b)) {
                mstore(0, 0x08c379a0)
                revert(0x1c, 4)
            }
            let at := add(add(b, 32), add(n, digits))
            for { let i := 0 } lt(i, digits) { i := add(i, 1) } {
                at := sub(at, 1)
                mstore8(at, add(48, mod(v, 10)))
                v := div(v, 10)
            }
            n := add(n, digits)
        }
        o.n = n;
    }

    /// A run of unit edges: "M{a} {b}{dir}{len}" (whole numbers). One capacity check.
    function run(Out memory o, uint256 a, uint256 b_, bytes1 dir, uint256 len) internal pure {
        bytes memory b = o.b;
        uint256 n = o.n;
        assembly ("memory-safe") {
            if gt(add(n, 40), mload(b)) {
                mstore(0, 0x08c379a0)
                revert(0x1c, 4)
            }
            function whole(p, w) -> q {
                let digits := 1
                for { let t := w } gt(t, 9) { t := div(t, 10) } { digits := add(digits, 1) }
                q := add(p, digits)
                let at := q
                for { let i := 0 } lt(i, digits) { i := add(i, 1) } {
                    at := sub(at, 1)
                    mstore8(at, add(48, mod(w, 10)))
                    w := div(w, 10)
                }
            }
            let start := add(add(b, 32), n)
            mstore8(start, 77) // M
            let p := whole(add(start, 1), a)
            mstore8(p, 32)
            p := whole(add(p, 1), b_)
            mstore8(p, shr(248, dir))
            p := whole(add(p, 1), len)
            n := add(n, sub(p, start))
        }
        o.n = n;
    }

    /// "#rrggbb" of mix `m` (0–15): the multiplied CMYK palette.
    function color(uint256 m) internal pure returns (bytes memory c) {
        uint256[4] memory inks = [uint256(0x00B5E2), 0xE4007C, 0xFFD100, 0x111111];
        uint256 r = 255;
        uint256 g = 255;
        uint256 bl = 255;
        for (uint256 l; l < 4; ++l) {
            if (m & (1 << l) == 0) continue;
            uint256 k = inks[l];
            r = (r * ((k >> 16) & 255) + 127) / 255;
            g = (g * ((k >> 8) & 255) + 127) / 255;
            bl = (bl * (k & 255) + 127) / 255;
        }
        uint256 rgb = (r << 16) | (g << 8) | bl;
        bytes16 hexd = "0123456789abcdef";
        c = new bytes(7);
        c[0] = "#";
        for (uint256 i; i < 6; ++i) {
            c[i + 1] = hexd[(rgb >> (4 * (5 - i))) & 15];
        }
    }

    /// The 16 palette colours, precomputed.
    function palette() internal pure returns (bytes[16] memory p) {
        for (uint256 m; m < 16; ++m) p[m] = color(m);
    }

    /// Plate mask of raster pixel i (0–143) of cell c, from the Statement's 240 ink words.
    function nib(uint256[240] memory ink, uint256 c, uint256 i) internal pure returns (uint256) {
        return (ink[c * 3 + (i >> 6)] >> ((i & 63) * 4)) & 15;
    }

    function popcount(uint256 m) internal pure returns (uint256) {
        return (m & 1) + ((m >> 1) & 1) + ((m >> 2) & 1) + ((m >> 3) & 1);
    }

    /// The Consolidated field: 76 × 92 plate masks, every cell's 12 × 12 raster on the 8-pixel
    /// pitch at +4 (a 6-pixel margin round the 64 × 80 of squares); overlapping ink ORs.
    function consolidated(uint256[240] memory ink) internal pure returns (bytes memory f) {
        f = new bytes(76 * 92);
        assembly ("memory-safe") {
            let fp := add(f, 32)
            for { let c := 0 } lt(c, 80) { c := add(c, 1) } {
                let base := add(fp, add(mul(add(mul(div(c, 8), 8), 4), 76), add(mul(mod(c, 8), 8), 4)))
                for { let k := 0 } lt(k, 3) { k := add(k, 1) } {
                    let w := mload(add(ink, mul(add(mul(c, 3), k), 32)))
                    if w {
                        for { let j := 0 } lt(j, 64) { j := add(j, 1) } {
                            let m := and(shr(mul(j, 4), w), 15)
                            if m {
                                let i := add(mul(k, 64), j)
                                let at := add(base, add(mul(div(i, 12), 76), mod(i, 12)))
                                mstore8(at, or(byte(0, mload(at)), m))
                            }
                        }
                    }
                }
            }
        }
    }
}
