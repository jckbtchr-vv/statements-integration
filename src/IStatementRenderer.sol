// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice A Statement format's drawing. Statements keeps an append-only list of these; a
///         Statement's format (chosen at compose, changeable by its owner) picks which one draws it.
///         A renderer reads whatever it needs back from Statements (inkOf, eightsOf, historyOf,
///         recordOf, composedFrom, ...) and returns fully on-chain art.
///
///         Black paper: from INVERTED_AT overprints on, Statements rewrites the SVG's colours in
///         place (#ffffff <-> #000000, #111111 -> #eeeeee). A renderer must write every colour as
///         '#' and six lower-case hex digits, and use '#' for nothing else in its SVG (no #fff, no
///         url(#id)), or its black paper won't come out right.
interface IStatementRenderer {
    /// @notice The Statement drawn as SVG (the metadata image).
    function svg(uint256 statementId) external view returns (string memory);

    /// @notice The Statement's interactive view as a self-contained HTML page (the metadata
    ///         animation_url), or an empty string when the format has none.
    function html(uint256 statementId) external view returns (string memory);
}

/// @notice The reads a renderer uses from Statements.
interface IStatementReads {
    function inkOf(uint256 statementId) external view returns (uint256[240] memory);
    function eightsOf(uint256 statementId) external view returns (uint256);
    function recordOf(uint256 statementId) external view returns (bytes memory);
    function composedFrom(uint256 statementId) external view returns (uint32[80] memory);
    function overprintsOf(uint256 statementId) external view returns (uint256);
    function historyOf(uint256 statementId, uint256 from, uint256 count) external view returns (uint256[] memory);
    function formatOf(uint256 statementId) external view returns (uint8);
}
