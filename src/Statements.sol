// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Utils} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Utils.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Credits} from "./Credits.sol";
import {StatementArt} from "./StatementArt.sol";
import {CreditScore} from "./CreditScore.sol";
import {IStatementRenderer} from "./IStatementRenderer.sol";
import {StatementBase64} from "./StatementBase64.sol";

/// @title Statements (compose and overprint: ink accumulates)
/// @notice Two moves. Compose burns 80 Credits into a new page. Overprint burns a whole page
///         onto another: every cell of the top page adds its ink to the same cell of the base.
///         Nothing is covered or lost: colors multiply and the page darkens with every
///         overprint. There is no limit: any page can be overprinted any number of times.
///         From its seventh overprint on (its eighth page), a page is printed on black paper, for good (INVERTED_AT).
///
///         A Credit's ink is its SHA-256 plates, kept only for the plates its payment second
///         selects and shifted by its misregistration, on a 12 × 12 raster per cell
///         (StatementArt.inkOf). Slipped ink overprints like any other. Proof marks are not drawn.
///
///         Credits is independent: this contract only calls its generic `burn`. Holders
///         approve this contract on Credits (setApprovalForAll) first. Burned Credits keep
///         their seed and timestamp in Credits, and each page keeps the ids it was composed
///         from, so every page's origin stays readable.
///
///         Overprinting needs both pages' owner, or an operator approved for all of the owner's
///         pages (setApprovalForAll); a single-page approval isn't enough. The
///         top token is burned; its record stays readable (overprintedWith, composedFrom).
///
///         Every page carries its Credit Score: the summed scores of every Credit burned into it,
///         overprints included. CreditScore computes each from the Credit's seed and payment
///         second, by the same formula as jack.art/credits/rating.
///
///         Every Statement takes a format, chosen when it is composed. Its owner can switch it to
///         any other format in the list at any time (setFormat); nothing else changes, and the
///         drawing redraws in the new format. Overprinting keeps the base's format; the drawing
///         redraws in it with every page.
///         Formats live in an append-only list: each is a name and a renderer contract
///         (IStatementRenderer) that draws the Statement fully on-chain, as SVG (the metadata
///         image) and optionally an interactive HTML view (statementHTML). The view is not in the
///         metadata: marketplaces frame an animation_url in a shape of their own, so every
///         Statement shows there as its 4:5 image, in every format alike. The owner can add
///         formats, never change or remove one, and can seal the list for good. A format's
///         renderer is fixed once added: a format always draws the same way.
///
///         Beyond adding formats, the owner role has no powers over pages; it exists for that and
///         for marketplace collection management.
contract Statements is ERC721, Ownable {
    uint256 public constant SIZE = 80;

    Credits public immutable credits;
    StatementArt public immutable art;
    CreditScore public immutable score;

    uint256 public supply;

    /// Accumulated ink in 180 words: cell c's first two words of StatementArt.inkOf's layout at 2c
    /// and 2c + 1, and its third (the raster's last 16 pixels, 64 bits) in word 160 + c / 4 at bits
    /// 64 × (c % 4). inkOf unpacks it to three words per cell.
    mapping(uint256 id => uint256[180] ink) private _ink;
    /// Eights marks per cell: the most eights (capped at 4, as the Credit draws them) any Credit
    /// burned into that cell carried. Cell c at bits 3c..3c+2.
    mapping(uint256 id => uint256 packed) private _eights;
    /// Pages overprinted directly onto this one, in order. Their records stay readable.
    mapping(uint256 id => uint256[] ids) private _overprintedWith;

    /// A page's record and counts, in one slot.
    struct Page {
        /// The contract whose code is the page's record, written once at compose (_store): the 80
        /// Credits as 29-byte records (21-byte seed, 8-byte payment second; recordOf), then their
        /// ids, four bytes each (composedFrom).
        address record;
        /// The Statement's format, an index into the format list: chosen at compose, changed only
        /// by its owner (setFormat).
        uint8 format;
        /// Pages overprinted onto this one, directly or through pages it absorbed. The edition's
        /// 122,154 Credits make at most 1,526 pages, so at most 1,525.
        uint32 overprints;
        /// Summed Credit Score of every Credit burned into this page (itself and every page
        /// overprinted onto it), in ten-thousandths. Each Credit's score is computed by
        /// CreditScore, at most 8,000,000: the whole edition sums to under 2^40.
        uint56 score;
    }

    mapping(uint256 id => Page) private _pages;

    /// recordOf's length: SIZE records of 29 bytes. The record contract holds them, then SIZE ids
    /// of four bytes.
    uint256 internal constant RECORD = 2320;

    struct Format {
        IStatementRenderer renderer;
        string name;
    }

    /// The formats, in the order they were added. Append-only; an entry never changes.
    Format[] private _formats;
    /// Set for good by seal(): no more formats can be added.
    bool public formatsSealed;
    /// @notice Composition opens at this Unix second. Fixed at deployment; nobody can change it.
    uint64 public immutable composeOpensAt;

    error Unknown();
    error NotAuthorized();
    error IdTooLarge();
    error SamePage();
    error BadFormat();
    error FormatsSealed();
    error TooManyFormats();
    error NotAContract();
    error BadName();
    error ComposeNotOpen(uint64 opensAt);

    event Composed(uint256 indexed statementId, address indexed by, uint256[80] creditIds, uint8 format);
    event Overprinted(uint256 indexed baseId, uint256 indexed topId, address indexed by);
    /// ERC-4906: the base's image and traits changed, so marketplaces refresh their cached metadata.
    event MetadataUpdate(uint256 _tokenId);
    event FormatAdded(uint8 indexed format, address renderer, string name);
    event FormatsSealedForGood();
    event FormatChanged(uint256 indexed statementId, uint8 from, uint8 to);

    constructor(address owner_, address credits_, uint64 opensAt_) ERC721("Statements", "STATEMENT") Ownable(owner_) {
        credits = Credits(credits_);
        composeOpensAt = opensAt_;
        score = new CreditScore();
        art = new StatementArt();
    }

    // ------------------------------------------------------------------ formats

    /// @notice Add a format: `renderer` draws every Statement composed in it, under `name`.
    ///         Formats are numbered in the order they are added; an added format never changes.
    function addFormat(address renderer, string calldata name) external onlyOwner returns (uint8 format) {
        if (formatsSealed) revert FormatsSealed();
        if (_formats.length > type(uint8).max) revert TooManyFormats();
        if (renderer.code.length == 0) revert NotAContract();
        // The name goes into the metadata JSON as is, inside a data: URI, so it must need no escaping.
        bytes memory n = bytes(name);
        if (n.length == 0 || n.length > 64) revert BadName();
        for (uint256 i; i < n.length; ++i) {
            bytes1 ch = n[i];
            if (ch < 0x20 || ch > 0x7e || ch == '"' || ch == "\\" || ch == "#" || ch == "%") revert BadName();
        }
        format = uint8(_formats.length);
        _formats.push(Format(IStatementRenderer(renderer), name));
        emit FormatAdded(format, renderer, name);
    }

    /// @notice Close the format list for good.
    function seal() external onlyOwner {
        if (formatsSealed) revert FormatsSealed();
        formatsSealed = true;
        emit FormatsSealedForGood();
    }

    function formatCount() external view returns (uint256) {
        return _formats.length;
    }

    function rendererOf(uint8 format) public view returns (IStatementRenderer) {
        if (format >= _formats.length) revert BadFormat();
        return _formats[format].renderer;
    }

    // ------------------------------------------------------------------ moves

    /// @notice Burn 80 owned Credits into a new page, cell i = creditIds[i], in `format` (an
    ///         index into the format list). The owner can change the format later (setFormat).
    ///         A contract recipient must accept the NFT through IERC721Receiver.
    function compose(uint256[80] calldata creditIds, uint8 format) external returns (uint256 statementId) {
        return _compose(creditIds, format, msg.sender);
    }

    /// @notice As compose, with the new page minted to `to`: for a contract that holds Credits
    ///         (a pool, say) composing for someone else. The Credits are still the caller's own.
    ///         A contract recipient must accept the NFT through IERC721Receiver.
    function compose(uint256[80] calldata creditIds, uint8 format, address to) external returns (uint256 statementId) {
        return _compose(creditIds, format, to);
    }

    function _compose(uint256[80] calldata creditIds, uint8 format, address to) private returns (uint256 statementId) {
        if (block.timestamp < composeOpensAt) revert ComposeNotOpen(composeOpensAt);
        if (format >= _formats.length) revert BadFormat();
        statementId = ++supply;
        uint256[] memory ids = new uint256[](SIZE);
        uint256[180] storage ink = _ink[statementId];
        // The record contract's data: the 80 records, then the 80 ids. 32 spare bytes so the last
        // word writes stay inside the allocation.
        bytes memory record = new bytes(RECORD + 4 * SIZE + 32);
        uint256 total;
        uint256 eights;
        uint256 tails; // third words of the current four cells
        for (uint256 i; i < SIZE; ++i) {
            uint256 creditId = creditIds[i];
            if (creditId == 0 || creditId > type(uint32).max) revert IdTooLarge();
            ids[i] = creditId;
            bytes21 seed = credits.seedOf(creditId);
            uint64 paidAt = credits.timestampOf(creditId);
            assembly ("memory-safe") {
                let at := add(add(record, 32), mul(i, 29))
                mstore(at, seed)
                mstore(add(at, 21), shl(192, paidAt))
            }
            (uint256[3] memory cell, uint256 mask, uint256 active, uint256 occupied, uint256 eightsIn, uint256 band) =
                art.inkAndTraits(seed, paidAt);
            total += score.scoreOfTraits(mask, active, occupied, eightsIn, band);
            eights |= (eightsIn > 4 ? 4 : eightsIn) << (3 * i); // marks show at most four
            ink[i * 2] = cell[0];
            ink[i * 2 + 1] = cell[1];
            tails |= cell[2] << (64 * (i % 4));
            if (i % 4 == 3) {
                if (tails != 0) ink[160 + i / 4] = tails;
                tails = 0;
            }
        }
        assembly ("memory-safe") {
            // Each id, four bytes, after the records (RECORD, 2320 bytes); a word write's spill is
            // overwritten by the next.
            let at := add(add(record, 32), 2320)
            for { let i := 0 } lt(i, 80) { i := add(i, 1) } {
                mstore(add(at, shl(2, i)), shl(224, mload(add(ids, shl(5, add(i, 1))))))
            }
        }
        // total: at most SIZE × 8,000,000, well inside 56 bits.
        _pages[statementId] = Page(_store(record, RECORD + 4 * SIZE), format, 0, uint56(total));
        if (eights != 0) _eights[statementId] = eights;
        credits.burn(msg.sender, ids);
        _mint(to, statementId);
        emit Composed(statementId, msg.sender, creditIds, format);
        // The same acceptance check as _safeMint, after Composed so receiver actions follow it.
        // A rejection reverts the entire composition, including every Credit burn.
        ERC721Utils.checkOnERC721Received(msg.sender, address(0), to, statementId, "");
    }

    /// @notice Switch the Statement to another format. Only its owner (not an approved operator)
    ///         can; the ink, history and score stay as they are, and the drawing redraws in `format`.
    function setFormat(uint256 statementId, uint8 format) external {
        if (_requireOwned(statementId) != msg.sender) revert NotAuthorized();
        if (format >= _formats.length) revert BadFormat();
        Page storage page = _pages[statementId];
        uint8 from = page.format;
        if (from == format) return;
        page.format = format;
        emit FormatChanged(statementId, from, format);
        emit MetadataUpdate(statementId);
    }

    /// @notice Burn `topId` onto `baseId`: every top cell adds its ink to the same base cell.
    ///         Any page onto any page, whatever their formats; the base keeps its own.
    ///         The caller must own both, or be approved for all of their owner's pages.
    function overprint(uint256 baseId, uint256 topId) external {
        if (baseId == topId) revert SamePage();
        _requireAuthorized(baseId);
        _requireAuthorized(topId);
        uint256[180] storage base = _ink[baseId];
        uint256[180] memory top = _ink[topId];
        for (uint256 i; i < 180; ++i) {
            uint256 word = top[i];
            if (word == 0) continue;
            uint256 merged = base[i] | word;
            if (merged != base[i]) base[i] = merged;
        }
        Page memory top_ = _pages[topId];
        Page storage base_ = _pages[baseId];
        base_.overprints += 1 + top_.overprints;
        base_.score += top_.score;
        uint256 topEights = _eights[topId];
        if (topEights != 0) {
            uint256 baseEights = _eights[baseId];
            uint256 merged;
            for (uint256 c; c < SIZE; ++c) {
                uint256 a = (baseEights >> (3 * c)) & 7;
                uint256 b = (topEights >> (3 * c)) & 7;
                merged |= (a > b ? a : b) << (3 * c);
            }
            if (merged != baseEights) _eights[baseId] = merged;
        }
        _overprintedWith[baseId].push(topId);
        _burn(topId);
        emit Overprinted(baseId, topId, msg.sender);
        emit MetadataUpdate(baseId);
    }

    // ------------------------------------------------------------------ reads

    /// @notice The page's ink, three words per cell (cell c at 3c..3c+2), in StatementArt.inkOf's layout.
    function inkOf(uint256 statementId) public view returns (uint256[240] memory ink) {
        _requireKnown(statementId);
        uint256[180] storage packed = _ink[statementId];
        uint256 tails;
        for (uint256 c; c < SIZE; ++c) {
            if (c % 4 == 0) tails = packed[160 + c / 4];
            ink[3 * c] = packed[2 * c];
            ink[3 * c + 1] = packed[2 * c + 1];
            ink[3 * c + 2] = (tails >> (64 * (c % 4))) & type(uint64).max;
        }
    }

    /// @notice The eights marks each cell shows (0–4), cell c at bits 3c..3c+2.
    function eightsOf(uint256 statementId) public view returns (uint256) {
        _requireKnown(statementId);
        return _eights[statementId];
    }

    /// @notice The 80 Credit ids a page was composed from, in order.
    function composedFrom(uint256 statementId) external view returns (uint32[80] memory) {
        _requireKnown(statementId);
        bytes memory packed = _read(_pages[statementId].record, RECORD, 4 * SIZE);
        uint32[80] memory ids;
        assembly ("memory-safe") {
            for { let i := 0 } lt(i, 80) { i := add(i, 1) } {
                mstore(add(ids, shl(5, i)), shr(224, mload(add(add(packed, 32), shl(2, i)))))
            }
        }
        return ids;
    }

    /// @notice The page's 80 Credits as 29-byte records: 21-byte seed, then 8-byte payment second.
    function recordOf(uint256 statementId) external view returns (bytes memory) {
        _requireKnown(statementId);
        return _read(_pages[statementId].record, 0, RECORD);
    }

    /// @notice Summed Credit Score of every Credit burned into this page (itself and every page
    ///         overprinted onto it), in ten-thousandths. 0 for an id never composed.
    function creditScoreOf(uint256 id) external view returns (uint256 total) {
        return _pages[id].score;
    }

    /// @notice Pages overprinted onto this one, directly or through pages it absorbed. 0 for an id
    ///         never composed.
    function overprintsOf(uint256 id) external view returns (uint256 count) {
        return _pages[id].overprints;
    }

    /// @notice How many pages a Statement holds: itself plus every page overprinted into it.
    function historyLength(uint256 statementId) public view returns (uint256) {
        _requireKnown(statementId);
        return 1 + uint256(_pages[statementId].overprints);
    }

    /// @notice A Statement's pages in layer order, `count` of them from position `from`: the page
    ///         itself first, then each page overprinted onto it, in order, each followed by its
    ///         own. Layer n of the artwork is pages 0..n printed together (recordOf each page for
    ///         its 80 Credits). Every viewer assembling a Statement's history uses this order.
    function historyOf(uint256 statementId, uint256 from, uint256 count)
        external
        view
        returns (uint256[] memory pages)
    {
        uint256 total = historyLength(statementId);
        if (from >= total) return new uint256[](0);
        if (count > total - from) count = total - from;
        pages = new uint256[](count);
        uint256[] memory stack = new uint256[](total);
        uint256 depth = 1;
        uint256 position;
        stack[0] = statementId;
        while (depth > 0 && position < from + count) {
            uint256 id = stack[--depth];
            if (position >= from) pages[position - from] = id;
            ++position;
            uint256[] storage tops = _overprintedWith[id];
            for (uint256 t = tops.length; t > 0; --t) {
                stack[depth++] = tops[t - 1];
            }
        }
    }

    function overprintedWith(uint256 statementId) external view returns (uint256[] memory) {
        _requireKnown(statementId);
        return _overprintedWith[statementId];
    }

    /// @notice Credits burned into this page: 80 for itself and 80 for every page overprinted onto it.
    function creditsOf(uint256 statementId) public view returns (uint256) {
        _requireKnown(statementId);
        return SIZE * (1 + uint256(_pages[statementId].overprints));
    }

    /// @notice The Statement's format: its index in the format list.
    function formatOf(uint256 statementId) public view returns (uint8) {
        _requireKnown(statementId);
        return _pages[statementId].format;
    }

    /// @notice The format's name, as the metadata trait shows it.
    function formatName(uint8 format) public view returns (string memory) {
        if (format >= _formats.length) revert BadFormat();
        return _formats[format].name;
    }

    /// @notice The Statement drawn in its format, as SVG. From INVERTED_AT overprints on, on black paper.
    function statementSVG(uint256 statementId) public view returns (string memory) {
        _requireKnown(statementId);
        Page storage page = _pages[statementId];
        return string(_drawn(statementId, _formats[page.format].renderer, page.overprints));
    }

    /// @notice From this many overprints on, a Statement is printed on black paper, for good: the
    ///         paper and pure black trade places (#ffffff <-> #000000), black ink alone turns
    ///         #eeeeee, and every other colour stays. Overprints only ever add up, so it never
    ///         flips back. The interactive view does the same from its eighth page.
    uint256 public constant INVERTED_AT = 7;

    function _drawn(uint256 statementId, IStatementRenderer renderer, uint256 overprints)
        private
        view
        returns (bytes memory svg)
    {
        svg = bytes(renderer.svg(statementId));
        if (overprints >= INVERTED_AT) _swapPaper(svg);
    }

    /// @dev The paper swap, in place. Every format writes its colours as '#' and six lower-case hex
    ///      digits, and '#' appears nowhere else in its SVG. Scans a word at a time for '#'.
    function _swapPaper(bytes memory svg) private pure {
        assembly ("memory-safe") {
            let start := add(svg, 32)
            let end := add(start, mload(svg))
            for { let p := start } lt(p, end) { p := add(p, 32) } {
                // Any byte of this word equal to '#' (0x23)? (the zero-byte test on word xor '#'s)
                let x := xor(mload(p), 0x2323232323232323232323232323232323232323232323232323232323232323)
                if and(and(sub(x, 0x0101010101010101010101010101010101010101010101010101010101010101), not(x)), 0x8080808080808080808080808080808080808080808080808080808080808080) {
                    let wend := add(p, 32)
                    if gt(wend, end) { wend := end }
                    for { let q := p } lt(q, wend) { q := add(q, 1) } {
                        if and(eq(byte(0, mload(q)), 0x23), iszero(gt(add(q, 7), end))) {
                            let to := 0
                            switch shr(208, mload(add(q, 1)))
                            case 0x666666666666 { to := 0x303030303030 } // ffffff -> 000000
                            case 0x303030303030 { to := 0x666666666666 } // 000000 -> ffffff
                            case 0x313131313131 { to := 0x656565656565 } // 111111 -> eeeeee
                            if to {
                                for { let j := 0 } lt(j, 6) { j := add(j, 1) } {
                                    mstore8(add(q, add(1, j)), byte(add(26, j), to))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// @notice The interactive view, in the Statement's format (empty if the format has none).
    function statementHTML(uint256 statementId) public view returns (string memory) {
        _requireKnown(statementId);
        return _formats[_pages[statementId].format].renderer.html(statementId);
    }

    /// @notice The Statements `owner_` holds, in ascending id order (none for the zero address).
    ///         Scans every id: for reading off-chain (eth_call), not for other contracts.
    function tokensOf(address owner_) external view returns (uint256[] memory) {
        if (owner_ == address(0)) return new uint256[](0);
        uint256[] memory ids = new uint256[](balanceOf(owner_));
        uint256 n;
        for (uint256 id = 1; n < ids.length; ++id) {
            if (_ownerOf(id) == owner_) ids[n++] = id;
        }
        return ids;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        Page memory page = _pages[tokenId];
        Format storage format = _formats[page.format];
        // The JSON goes out as plain text (not base64): encoding the image twice costs as
        // much gas as drawing them. Every field is a number, base64 or a format name (addFormat
        // admits only printable ASCII, and no quote, backslash, '#' or '%'), so nothing needs escaping; the name's
        // '#' is written \u0023 so the data URI carries no fragment mark.
        bytes memory head = bytes.concat(
            'data:application/json;utf8,{"name":"Statement \\u0023',
            bytes(Strings.toString(tokenId)),
            '","description":"From state: to declare where one stands.","image":"data:image/svg+xml;base64,'
        );
        bytes memory tail = bytes(
            string.concat(
                '","attributes":[{"trait_type":"Format","value":"',
                format.name,
                '"},{"trait_type":"Credits","value":',
                Strings.toString(SIZE * (1 + uint256(page.overprints))),
                '},{"trait_type":"Overprints","value":',
                Strings.toString(page.overprints),
                '},{"trait_type":"Credit Rating","value":',
                Strings.toString(page.score / 10_000),
                "}]}"
            )
        );
        return _json(head, _drawn(tokenId, format.renderer, page.overprints), tail);
    }

    /// @dev The metadata in one buffer, each piece written once: `head`, the image's Base64, `tail`.
    function _json(bytes memory head, bytes memory image, bytes memory tail)
        private
        pure
        returns (string memory json)
    {
        uint256 length = head.length + (image.length + 2) / 3 * 4 + tail.length;
        uint256 at;
        assembly ("memory-safe") {
            json := mload(0x40)
            mstore(json, length)
            at := add(json, 32)
            // StatementBase64.write can run 28 bytes past its end: 32 spare.
            mstore(0x40, and(add(add(at, length), 63), not(31)))
        }
        at = _put(at, head);
        at = StatementBase64.write(at, image);
        _put(at, tail);
    }

    /// @dev Copies `piece` to memory address `at`; returns the address just past it.
    function _put(uint256 at, bytes memory piece) private pure returns (uint256 end) {
        assembly ("memory-safe") {
            let length := mload(piece)
            mcopy(at, add(piece, 32), length)
            end := add(at, length)
        }
    }

    /// @dev ERC-4906 (metadata updates) on top of ERC-721.
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == bytes4(0x49064906) || super.supportsInterface(interfaceId);
    }

    // ------------------------------------------------------------------ internals

    function _requireKnown(uint256 statementId) private view {
        if (statementId == 0 || statementId > supply) revert Unknown();
    }

    /// The page's owner, or an operator it approved for all its pages. A single-page approval
    /// (getApproved) is for moving that page only: it can't overprint onto it or burn it.
    function _requireAuthorized(uint256 statementId) private view {
        address owner_ = _requireOwned(statementId);
        if (msg.sender != owner_ && !isApprovedForAll(owner_, msg.sender)) revert NotAuthorized();
    }

    /// @dev SSTORE2: `data`'s first `length` bytes become the code of a new contract, behind a STOP
    ///      (0x00) so it can never run; _read gives them back. The creation code goes over the
    ///      length word, just before the data: PUSH2 length + 1, DUP1, PUSH1 10, RETURNDATASIZE (0),
    ///      CODECOPY, RETURNDATASIZE, RETURN, then the STOP it returns with the data. A failed create
    ///      reverts with no data, as running out of gas does. PUSH2 caps `length` below 65,535
    ///      (compose stores 2,640).
    function _store(bytes memory data, uint256 length) private returns (address pointer) {
        assert(length < 0xffff);
        assembly ("memory-safe") {
            let word := mload(data)
            mstore(data, or(0x61000080600a3d393df300, shl(64, add(length, 1))))
            pointer := create(0, add(data, 21), add(length, 11))
            if iszero(pointer) { revert(0, 0) }
            mstore(data, word)
        }
    }

    /// @dev `length` bytes of a record contract's data, from `offset` (past its STOP).
    function _read(address pointer, uint256 offset, uint256 length) private view returns (bytes memory data) {
        data = new bytes(length);
        assembly ("memory-safe") {
            extcodecopy(pointer, add(data, 32), add(offset, 1), length)
        }
    }
}
