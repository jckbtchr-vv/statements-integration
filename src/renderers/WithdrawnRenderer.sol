// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IStatementRenderer, IStatementReads} from "../IStatementRenderer.sol";

/// @notice A blank white page, including Statements which reached black paper.
/// The registry permits any owner to select any format: this image alone is NOT evidence
/// of withdrawal. Verify Withdrawals.receipts(id) and Statements.ownerOf(id).
contract WithdrawnRenderer is IStatementRenderer {
    IStatementReads public immutable statements;

    constructor(address statements_) {
        statements = IStatementReads(statements_);
    }

    function svg(uint256 id) external view returns (string memory) {
        // Statements inverts these exact colors after seven overprints. Compensate once.
        string memory paper = statements.overprintsOf(id) >= 7 ? "#000000" : "#ffffff";
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 76 95">',
            '<rect width="76" height="95" fill="',
            paper,
            '"/></svg>'
        );
    }

    function html(uint256) external pure returns (string memory) {
        return '<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">'
            "<title>Withdrawn Statement</title><style>html,body{margin:0;width:100%;height:100%;background:#fff}</style>"
            "</head><body></body></html>";
    }
}
