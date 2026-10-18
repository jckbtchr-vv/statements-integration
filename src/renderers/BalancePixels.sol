// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Draw} from "./Draw.sol";

/// @notice Balance numerals and WITHDRAWN lettering, without font files or SVG text.
/// Receipt uses a 5-by-7 matrix plus one comma descender row.
/// A 135-unit pitch preserves the prior 945-unit cap height and 4:5 page.
library BalancePixels {
    uint256 internal constant WIDTH = 5;
    uint256 internal constant ROWS = 8;
    uint256 internal constant ADVANCE = 6;
    uint256 internal constant PITCH = 135;
    uint256 internal constant TOP = 7875;
    uint256 internal constant FIELD_WIDTH = 13440;

    function draw(string memory number) internal pure returns (string memory) {
        bytes memory label = bytes(number);
        require(label.length > 0 && label.length <= 16, "Balance grid width");
        uint80[] memory masks = new uint80[](label.length);
        for (uint256 i; i < label.length; ++i) {
            masks[i] = _glyph(label[i]);
        }
        uint256 start = (FIELD_WIDTH - (label.length * ADVANCE - 1) * PITCH) / 2;
        Draw.Out memory out = Draw.init(24_000);
        Draw.str(out, '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16000 20000"><title>Balance: ');
        Draw.str(out, label);
        Draw.str(
            out,
            '</title><rect width="16000" height="20000" fill="#ffffff"/><g shape-rendering="crispEdges" transform="translate(1280 1600)">'
        );
        for (uint256 ink; ink < 4; ++ink) {
            Draw.str(out, '<path fill="');
            Draw.str(out, Draw.color(1 << ink));
            Draw.str(out, '" d="');
            for (uint256 row; row < ROWS; ++row) {
                for (uint256 i; i < label.length; ++i) {
                    for (uint256 col; col < WIDTH; ++col) {
                        if ((masks[i] & (uint80(1) << (row * WIDTH + col))) == 0) continue;
                        uint256 cellX = i * ADVANCE + col;
                        if ((cellX % 2) + 2 * (row % 2) != ink) continue;
                        Draw.run(out, start + cellX * PITCH, TOP + row * PITCH, "h", PITCH);
                        Draw.str(out, "v135h-135z");
                    }
                }
            }
            Draw.str(out, '"/>');
        }
        Draw.str(out, "</g></svg>");
        return Draw.done(out);
    }

    /// Row-major bits: row * 5 + column. Keep in parity with pixel-balance.mjs.
    function _glyph(bytes1 c) internal pure returns (uint80) {
        if (c == "0") return 0x3a33ae62e;
        if (c == "1") return 0x3884210c4;
        if (c == "2") return 0x7c226422e;
        if (c == "3") return 0x3e107420f;
        if (c == "4") return 0x211f4a988;
        if (c == "5") return 0x3e107843f;
        if (c == "6") return 0x3a317842e;
        if (c == "7") return 0x8422221f;
        if (c == "8") return 0x3a317462e;
        if (c == "9") return 0x3a10f462e;
        if (c == ".") return 0x100000000;
        if (c == ",") return 0x1100000000;
        if (c == "W") return 0x2ab5ac631;
        if (c == "I") return 0x38842108e;
        if (c == "T") return 0x10842109f;
        if (c == "H") return 0x4631fc631;
        if (c == "D") return 0x1d318c527;
        if (c == "R") return 0x45257c62f;
        if (c == "A") return 0x4631fc62e;
        if (c == "N") return 0x4639ace31;
        revert("Balance glyph");
    }
}
