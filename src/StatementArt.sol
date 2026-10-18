// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CreditDrawing} from "./CreditDrawing.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @notice 8×10 statement drawing. Premultiplied CMYK like one credit, with a
///         payment-time palette preserved for each Credit. Built into a linear buffer —
///         no repeated string concatenation.
contract StatementArt {
    uint256 internal constant COLS = 8;
    uint256 internal constant ROWS = 10;

    function eightsOf(bytes21[80] memory seeds) public pure returns (uint256 n) {
        for (uint256 i; i < COLS * ROWS; ++i) {
            n += _eights(seeds[i]);
        }
    }

    /// @notice Same 4:5 frame, spacing, offsets and mask behavior as the website PNG.
    function svg(bytes21[80] memory seeds, uint64[80] memory timestamps) external pure returns (string memory) {
        return _draw(seeds, timestamps, type(uint256).max);
    }

    /// @notice The ink one Credit lays down: its SHA-256 plates for the plates its payment
    ///         second selects, each shifted by the Credit's misregistration, on the 12 × 12
    ///         raster the renderer uses (the 8 × 8 square sits at 2..9). Packed as 144 four-bit
    ///         plate masks (C = 1, M = 2, Y = 4, K = 8): pixel i in word i / 64 at bits (i % 64) * 4.
    function inkOf(bytes21 seed, uint64 paidAt) public pure returns (uint256[3] memory ink) {
        (ink,,,,,) = inkAndTraits(seed, paidAt);
    }

    /// @notice inkOf and the five Credit Score traits in one pass, the values CreditScore.traitsOf
    ///         works out on its own: plate mask, active bits, occupied raster cells, eights in the
    ///         seed and registration band. Statements.compose scores each Credit from these.
    function inkAndTraits(bytes21 seed, uint64 paidAt)
        public
        pure
        returns (uint256[3] memory ink, uint256 mask, uint256 active, uint256 occupied, uint256 eights, uint256 band)
    {
        (int8[4] memory dx, int8[4] memory dy) = CreditDrawing.slips(seed);
        bytes32 hash = sha256(abi.encodePacked(seed));
        mask = uint256(paidAt) % 15 + 1; // the plates, as CreditDrawing.platesAt
        // A plate row at a time, straight into the packed words: the row's eight bits (x = 0 at
        // the high bit) are reversed, spread one to a four-bit lane, and shifted to the row's
        // first pixel on the raster. A row can straddle two words.
        assembly ("memory-safe") {
            let w0 := 0
            let w1 := 0
            let w2 := 0
            for { let layer := 0 } lt(layer, 4) { layer := add(layer, 1) } {
                if and(shr(layer, mask), 1) {
                    let ox := add(2, mload(add(dx, shl(5, layer))))
                    let oy := add(2, mload(add(dy, shl(5, layer))))
                    let plate := shr(192, shl(shl(6, layer), hash)) // 64 bits, row 0 in the high byte
                    // active bits: the plate's set bits, counted in parallel
                    let c := sub(plate, and(shr(1, plate), 0x5555555555555555))
                    c := add(and(c, 0x3333333333333333), and(shr(2, c), 0x3333333333333333))
                    c := and(add(c, shr(4, c)), 0x0f0f0f0f0f0f0f0f)
                    active := add(active, and(shr(56, mul(c, 0x0101010101010101)), 0xff))
                    for { let y := 0 } lt(y, 8) { y := add(y, 1) } {
                        let bits := and(shr(sub(56, shl(3, y)), plate), 0xff)
                        if bits {
                            // Reverse the byte (x = 0 to bit 0), then move bit k to bit 4k.
                            let lanes := mod(and(mul(bits, 0x0202020202), 0x010884422010), 1023)
                            lanes := and(or(lanes, shl(12, lanes)), 0x000f000f)
                            lanes := and(or(lanes, shl(6, lanes)), 0x03030303)
                            lanes := shl(layer, and(or(lanes, shl(3, lanes)), 0x11111111))
                            let at := shl(2, add(mul(add(y, oy), 12), ox)) // bit of the row's first pixel
                            let low := shl(and(at, 255), lanes)
                            let high := shr(sub(256, and(at, 255)), lanes) // lanes past the word, if any
                            switch shr(8, at)
                            case 0 {
                                w0 := or(w0, low)
                                w1 := or(w1, high)
                            }
                            case 1 {
                                w1 := or(w1, low)
                                w2 := or(w2, high)
                            }
                            default { w2 := or(w2, low) }
                        }
                    }
                }
            }
            mstore(ink, w0)
            mstore(add(ink, 32), w1)
            mstore(add(ink, 64), w2)
        }
        occupied = _inkedLanes(ink[0]) + _inkedLanes(ink[1]) + _inkedLanes(ink[2]);
        eights = _eights(seed);
        bytes32 misprint = sha256(abi.encodePacked(seed, "/misprint"));
        if (uint8(misprint[0]) < 32) {
            uint256 dice = uint8(misprint[1]);
            band = dice < 80 ? 1 : dice < 160 ? 2 : dice < 210 ? 3 : dice < 240 ? 4 : 5;
        }
    }

    /// @dev The '8's in a seed (CreditDrawing.eights), counted a word at a time: xor with '8's
    ///      zeroes exactly the bytes that were '8' (the 11 bytes past the seed turn 0x38), each zero
    ///      byte sets its bit 7 (no carry crosses a byte: (b & 0x7f) + 0x7f <= 0xfe), and one
    ///      multiply sums the flags into the top byte.
    function _eights(bytes21 seed) private pure returns (uint256 n) {
        assembly ("memory-safe") {
            let x := xor(
                and(seed, not(sub(shl(88, 1), 1))),
                0x3838383838383838383838383838383838383838383838383838383838383838
            )
            let low := 0x7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f
            let zero := not(or(or(add(and(x, low), low), x), low))
            n := shr(248, mul(shr(7, zero), 0x0101010101010101010101010101010101010101010101010101010101010101))
        }
    }

    /// @dev Four-bit lanes of `word` with any ink: each lane folded onto its low bit, then counted.
    function _inkedLanes(uint256 word) private pure returns (uint256) {
        word |= word >> 1;
        word |= word >> 2;
        word &= 0x1111111111111111111111111111111111111111111111111111111111111111;
        word = (word & 0x0101010101010101010101010101010101010101010101010101010101010101)
            + ((word >> 4) & 0x0101010101010101010101010101010101010101010101010101010101010101);
        unchecked {
            return (word * 0x0101010101010101010101010101010101010101010101010101010101010101) >> 248;
        }
    }

    /// @notice A page of accumulated ink: every Credit ever burned into a cell overprints there,
    ///         misregistration and all, with the cell's eights marks bottom right, as a Credit
    ///         draws them (1: K; 2: Y K; 3: M Y K; 4: C M Y K). Same 4:5 frame and cell
    ///         positions as svg(). `eights`: cell c's mark count at bits 3c..3c+2. Cells don't
    ///         clip (overflow visible), so the marks' edges fall on the same pixels as the
    ///         interactive view's at every size.
    function inkPage(uint256[240] memory ink, uint256 eights) external pure returns (string memory) {
        // Worst case (every run one pixel, 15 colors a cell, under-bleed both ways) stays under
        // 700 KB. Scratch: each mask's path data, then each mask's under-bleed (see _runs).
        CreditDrawing.Buffer memory out = CreditDrawing.Buffer(new bytes(700_000), 0, new bytes(16 * 2336 + 16 * 5232));
        CreditDrawing.put(
            out,
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10000 12500" shape-rendering="crispEdges"><rect width="10000" height="12500" fill="#ffffff"/>'
        );
        uint24[16] memory colors = CreditDrawing.palette();
        string[16] memory fills;
        for (uint256 m = 1; m < 16; ++m) {
            fills[m] = string.concat('<path fill="', CreditDrawing.hexColor(colors[m]), '" d="');
        }
        for (uint256 c; c < COLS * ROWS; ++c) {
            CreditDrawing.put(
                out,
                string.concat(
                    '<svg x="',
                    Strings.toString(800 + (c % COLS) * 1050),
                    '" y="',
                    Strings.toString(820 + (c / COLS) * 1090),
                    '" width="1050" height="1050" viewBox="0 0 16 16" overflow="visible">'
                )
            );
            _runs(out, fills, ink[c * 3], ink[c * 3 + 1], ink[c * 3 + 2]);
            uint256 n = (eights >> (3 * c)) & 7;
            for (uint256 i; i < n; ++i) {
                uint256 slot = 16 - n + i;
                CreditDrawing.put(
                    out,
                    string.concat(
                        '<rect x="', Strings.toString(slot), '" y="15" width="1" height="1" fill="',
                        CreditDrawing.hexColor(colors[1 << (slot - 12)]), '"/>'
                    )
                );
            }
            CreditDrawing.put(out, "</svg>");
        }
        CreditDrawing.put(out, "</svg>");
        return CreditDrawing.finish(out);
    }

    /// @dev One cell on a 16-unit box: pixel (x, y) of the 12 × 12 raster at (x + 2, y + 2), the
    ///      same place the 320-unit Credit drawing puts it. Horizontal runs of one plate mask are
    ///      merged, and each mask becomes one path.
    ///      Under them all, an under-bleed: each run again, half a pixel longer where the pixel to
    ///      its right has ink, and half a pixel taller under the stretches whose pixels below have
    ///      ink. It only ever lies under ink drawn on top, so a renderer that keeps hard edges
    ///      draws exactly the same pixels; one that smooths edges (some marketplaces' image
    ///      services) shows ink, not paper, where two inks meet.
    function _runs(CreditDrawing.Buffer memory out, string[16] memory fills, uint256 w0, uint256 w1, uint256 w2)
        private
        pure
    {
        bytes memory scratch = out.scratch;
        uint256[16] memory lengths;
        uint256[16] memory ulengths;
        assembly ("memory-safe") {
            function nib(i, a, b, c) -> m {
                let w := a
                if gt(i, 63) { w := b }
                if gt(i, 127) { w := c }
                m := and(shr(mul(mod(i, 64), 4), w), 15)
            }
            // Writes 1..16 as one or two digits; returns the next free position.
            function num(at, n) -> next {
                switch lt(n, 10)
                case 1 {
                    mstore8(at, add(48, n))
                    next := add(at, 1)
                }
                default {
                    mstore8(at, add(48, div(n, 10)))
                    mstore8(add(at, 1), add(48, mod(n, 10)))
                    next := add(at, 2)
                }
            }
            for { let y := 0 } lt(y, 12) { y := add(y, 1) } {
                let x := 0
                for {} lt(x, 12) {} {
                    let m := nib(add(mul(y, 12), x), w0, w1, w2)
                    let w := 1
                    for {} and(lt(add(x, w), 12), eq(nib(add(mul(y, 12), add(x, w)), w0, w1, w2), m)) {} {
                        w := add(w, 1)
                    }
                    if m {
                        let lengthAt := add(lengths, mul(m, 32))
                        let start := add(add(add(scratch, 32), mul(m, 2336)), mload(lengthAt))
                        mstore8(start, 77) // M
                        let at := num(add(start, 1), add(x, 2))
                        mstore8(at, 32) // space
                        at := num(add(at, 1), add(y, 2))
                        mstore8(at, 104) // h
                        at := num(add(at, 1), w)
                        mstore(at, "v1h-")
                        at := num(add(at, 4), w)
                        mstore8(at, 122) // z
                        mstore(lengthAt, add(mload(lengthAt), sub(add(at, 1), start)))
                        // The under-bleed, in this mask's second scratch area.
                        let ulengthAt := add(ulengths, mul(m, 32))
                        let ubase := add(add(add(scratch, 32), 37376), mul(m, 5232)) // 37376 = 16 × 2336
                        if and(lt(add(x, w), 12), gt(nib(add(mul(y, 12), add(x, w)), w0, w1, w2), 0)) {
                            // Under the pixel to the right: "M x y h w.5 v1 h-w.5 z".
                            let u := add(ubase, mload(ulengthAt))
                            mstore8(u, 77) // M
                            let a := num(add(u, 1), add(x, 2))
                            mstore8(a, 32)
                            a := num(add(a, 1), add(y, 2))
                            mstore8(a, 104) // h
                            a := num(add(a, 1), w)
                            mstore(a, ".5v1h-")
                            a := num(add(a, 6), w)
                            mstore(a, ".5z")
                            mstore(ulengthAt, add(mload(ulengthAt), sub(add(a, 3), u)))
                        }
                        if lt(y, 11) {
                            // Under the pixels below, stretch by stretch: "M x y h n v1.5 h-n z".
                            let i := 0
                            for {} lt(i, w) {} {
                                let j := i
                                for {} and(lt(j, w), gt(nib(add(mul(add(y, 1), 12), add(x, j)), w0, w1, w2), 0)) {} {
                                    j := add(j, 1)
                                }
                                switch gt(j, i)
                                case 1 {
                                    let u := add(ubase, mload(ulengthAt))
                                    mstore8(u, 77) // M
                                    let a := num(add(u, 1), add(add(x, i), 2))
                                    mstore8(a, 32)
                                    a := num(add(a, 1), add(y, 2))
                                    mstore8(a, 104) // h
                                    a := num(add(a, 1), sub(j, i))
                                    mstore(a, "v1.5h-")
                                    a := num(add(a, 6), sub(j, i))
                                    mstore8(a, 122) // z
                                    mstore(ulengthAt, add(mload(ulengthAt), sub(add(a, 1), u)))
                                    i := j
                                }
                                default { i := add(i, 1) }
                            }
                        }
                    }
                    x := add(x, w)
                }
            }
        }
        // The under-bleed first, every mask's, then the ink itself on top.
        for (uint256 pass; pass < 2; ++pass) {
            for (uint256 m = 1; m < 16; ++m) {
                uint256 length = pass == 0 ? ulengths[m] : lengths[m];
                if (length == 0) continue;
                uint256 from = pass == 0 ? 37376 + m * 5232 : m * 2336;
                CreditDrawing.put(out, fills[m]);
                require(out.used + length <= out.data.length, "SVG capacity");
                bytes memory data = out.data;
                uint256 used = out.used;
                assembly ("memory-safe") {
                    mcopy(add(add(data, 32), used), add(add(scratch, 32), from), length)
                }
                out.used = used + length;
                CreditDrawing.put(out, '"/>');
            }
        }
    }

    function _draw(bytes21[80] memory seeds, uint64[80] memory timestamps, uint256 mask)
        private
        pure
        returns (string memory)
    {
        CreditDrawing.Buffer memory out = CreditDrawing.Buffer(new bytes(400_000), 0, new bytes(16 * 2768));
        CreditDrawing.put(
            out,
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10000 12500" shape-rendering="crispEdges"><rect width="10000" height="12500" fill="#ffffff"/>'
        );
        uint24[16] memory colors = CreditDrawing.palette();
        for (uint256 i; i < COLS * ROWS; ++i) {
            if (mask & (1 << i) == 0) continue;
            CreditDrawing.put(
                out,
                string.concat(
                    '<svg x="',
                    Strings.toString(800 + (i % COLS) * 1050),
                    '" y="',
                    Strings.toString(820 + (i / COLS) * 1090),
                    '" width="1050" height="1050" viewBox="0 0 320 320">'
                )
            );
            CreditDrawing.body(out, seeds[i], CreditDrawing.platesAt(timestamps[i]), colors, true);
            CreditDrawing.put(out, "</svg>");
        }
        CreditDrawing.put(out, "</svg>");
        return CreditDrawing.finish(out);
    }
}
