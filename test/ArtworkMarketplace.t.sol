// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {WithdrawalsFixture} from "./Withdrawals.t.sol";
import {LineageWithdrawals} from "../src/experimental/LineageWithdrawals.sol";
import {LineageArtwork} from "../src/experimental/LineageArtwork.sol";

/// @dev Contract-side marketplace compatibility, not evidence of an OpenSea crawl.
contract ArtworkMarketplaceTest is WithdrawalsFixture {
    LineageWithdrawals internal token;
    LineageArtwork internal art;

    function setUp() public override {
        super.setUp();
        token = new LineageWithdrawals(address(statements), 2);
        statements.addFormat(address(token.renderer()), "Balance");
        art = token.artwork();
    }

    function release(uint256 page) internal returns (uint256 amount) {
        uint256 statement = compose(page);
        amount = token.quote(statement);
        vm.startPrank(ALICE);
        statements.approve(address(token), statement);
        token.withdraw(statement, amount);
        vm.stopPrank();
    }

    function decodeURI(string memory uri, string memory prefix) internal pure returns (string memory) {
        bytes memory raw = bytes(uri);
        bytes memory start = bytes(prefix);
        require(raw.length > start.length, "Empty data URI");
        bytes memory payload = new bytes(raw.length - start.length);
        for (uint256 i; i < start.length; ++i) require(raw[i] == start[i], "Wrong MIME type");
        for (uint256 i; i < payload.length; ++i) payload[i] = raw[i + start.length];
        return string(Base64.decode(string(payload)));
    }

    function metadata(address wallet) internal view returns (string memory) {
        return decodeURI(art.tokenURI(art.tokenIdOf(wallet)), "data:application/json;base64,");
    }

    function trait(string memory json, string memory name) internal view returns (string memory path) {
        for (uint256 i; i < 32; ++i) {
            path = string.concat(".attributes[", vm.toString(i), "]");
            if (!vm.keyExistsJson(json, path)) break;
            if (keccak256(bytes(vm.parseJsonString(json, string.concat(path, ".trait_type")))) == keccak256(bytes(name))) return path;
        }
        revert("Missing trait");
    }

    function countEvent(Vm.Log[] memory logs, string memory signature, uint256 id) internal view returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(art) && logs[i].topics[0] == keccak256(bytes(signature))) {
                assertEq(logs[i].topics.length, 1, "Marketplace event token ID must be in data");
                if (abi.decode(logs[i].data, (uint256)) == id) ++count;
            }
        }
    }

    function testDustDisplayBoundariesAndZero() public {
        release(0);
        assertEq(token.renderer().displayTokenBalance(0), "0");
        assertEq(token.renderer().displayTokenBalance(1), "<0.01");
        assertEq(token.renderer().displayTokenBalance(1e16 - 1), "<0.01");
        assertEq(token.renderer().displayTokenBalance(1e16), "0.01");
        assertEq(token.renderer().displayTokenBalance(1e16 + 1), "0.01");
        vm.prank(ALICE); token.transfer(BOB, 1);
        string memory image = art.svg(art.tokenIdOf(BOB));
        assertTrue(contains(image, "BALANCE: &lt;0.01</title>"));
        assertFalse(contains(image, "BALANCE: <0.01"));
        assertEq(art.displayBalance(BOB), "0.000000000000000001");
        vm.prank(BOB); token.transfer(ALICE, 1);
        assertEq(art.artworkBalance(BOB), "0");
    }

    function testCollectionMetadataWorksBeforeFirstReceipt() public view {
        assertEq(art.totalSupply(), 0);
        string memory json = decodeURI(art.contractURI(), "data:application/json;base64,");
        assertEq(vm.parseJsonString(json, ".name"), art.name());
        assertEq(vm.parseJsonString(json, ".external_link"), "https://jack.art/credits/balances/");
        uint256[4] memory emptyInk;
        assertEq(decodeURI(vm.parseJsonString(json, ".image"), "data:image/svg+xml;base64,"), token.renderer().drawTokenBalance(0, emptyInk));
    }

    function testMetadataIsValidExactAndMarketplaceTyped() public {
        release(0);
        string memory json = metadata(ALICE);
        assertEq(vm.parseJsonString(json, ".name"), string.concat("Balance #", vm.toString(art.tokenIdOf(ALICE))));
        assertEq(vm.parseJsonString(json, ".background_color"), "ffffff");
        assertEq(vm.parseJsonString(json, ".external_url"), "https://jack.art/credits/balances/");
        assertEq(vm.parseJsonString(json, string.concat(trait(json, "Balance"), ".value")), art.displayBalance(ALICE));
        assertEq(vm.parseJsonString(json, string.concat(trait(json, "Transferability"), ".value")), "Wallet-bound");
        string memory date = trait(json, "First receipt timestamp");
        assertEq(vm.parseJsonString(json, string.concat(date, ".display_type")), "date");
        assertEq(vm.parseJsonUint(json, string.concat(date, ".value")), block.timestamp);
        string memory count = trait(json, "Statements surrendered");
        assertEq(vm.parseJsonString(json, string.concat(count, ".display_type")), "number");
        assertEq(vm.parseJsonUint(json, string.concat(count, ".value")), 1);
        // Atomic units exceed JavaScript's safe integer range; retain them as strings.
        assertEq(vm.parseJsonString(json, string.concat(trait(json, "Received units"), ".value")), vm.toString(token.balanceOf(ALICE)));
        string memory svg = decodeURI(vm.parseJsonString(json, ".image"), "data:image/svg+xml;base64,");
        assertEq(svg, art.svg(art.tokenIdOf(ALICE)));
        assertTrue(contains(svg, 'width="3000" height="3750" viewBox="0 0 16000 20000"'));
        assertTrue(contains(svg, '<rect width="16000" height="20000" fill="#ffffff"'));
        assertFalse(contains(svg, "<script"));
        assertFalse(contains(svg, "<text"));
        assertFalse(contains(svg, "href="));
        assertFalse(contains(svg, "<foreignObject"));
    }

    function testReceiptIssuesSequentialIdEvenForLargeWalletAddress() public {
        uint256 amount = release(0);
        address recipient = address(type(uint160).max - 1);
        vm.recordLogs();
        vm.prank(ALICE);
        token.transfer(recipient, amount);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 id = 2;
        assertEq(art.tokenIdOf(ALICE), 1);
        assertEq(art.tokenIdOf(recipient), id);
        assertEq(art.ownerOf(id), recipient);
        assertTrue(art.locked(id));
        assertEq(countEvent(logs, "Locked(uint256)", id), 1);
        uint256 mints;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(art) || logs[i].topics[0] != keccak256("Transfer(address,address,uint256)")) continue;
            assertEq(logs[i].topics.length, 4);
            assertEq(logs[i].topics[1], bytes32(0));
            assertEq(uint256(logs[i].topics[2]), uint256(uint160(recipient)));
            assertEq(uint256(logs[i].topics[3]), id);
            ++mints;
        }
        assertEq(mints, 1);
        assertEq(vm.parseJsonAddress(metadata(recipient), ".attributes[0].value"), recipient);
    }

    function testUpdatesBothExistingArtworksIncludingZeroAndReturn() public {
        uint256 amount = release(0);
        vm.prank(ALICE);
        token.transfer(BOB, 1);
        uint256 aliceId = art.tokenIdOf(ALICE);
        uint256 bobId = art.tokenIdOf(BOB);
        vm.recordLogs();
        vm.prank(ALICE);
        token.transfer(BOB, amount - 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(countEvent(logs, "MetadataUpdate(uint256)", aliceId), 1);
        assertEq(countEvent(logs, "MetadataUpdate(uint256)", bobId), 1);
        assertEq(vm.parseJsonString(metadata(ALICE), ".name"), string.concat("Balance #", vm.toString(aliceId)));
        assertEq(art.ownerOf(aliceId), ALICE);
        assertEq(art.balanceOf(ALICE), 1);
        assertFalse(contains(art.svg(aliceId), "9135h")); // no ink underline at zero
        vm.recordLogs();
        vm.prank(BOB);
        token.transfer(ALICE, amount);
        logs = vm.getRecordedLogs();
        assertEq(countEvent(logs, "MetadataUpdate(uint256)", aliceId), 1);
        assertEq(countEvent(logs, "MetadataUpdate(uint256)", bobId), 1);
        assertEq(countEvent(logs, "Locked(uint256)", aliceId), 0); // same permanent artwork
        assertEq(art.totalSupply(), 2);
        assertEq(art.tokenIdOf(ALICE), aliceId);
    }

    function testNoSpuriousMintOrRefreshOnZeroOrSelfTransfer() public {
        release(0);
        vm.recordLogs();
        vm.startPrank(ALICE);
        token.transfer(ALICE, 1);
        token.transfer(BOB, 0);
        vm.stopPrank();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) assertTrue(logs[i].emitter != address(art));
        assertEq(art.tokenIdOf(BOB), 0);
    }

    function testSupportedInterfacesAndAllTradingPathsStayLocked() public {
        release(0);
        uint256 id = art.tokenIdOf(ALICE);
        assertTrue(art.supportsInterface(0x01ffc9a7)); // ERC-165
        assertTrue(art.supportsInterface(0x80ac58cd)); // ERC-721
        assertTrue(art.supportsInterface(0x5b5e139f)); // metadata
        assertTrue(art.supportsInterface(0xb45a3c0e)); // ERC-5192
        assertTrue(art.supportsInterface(0x49064906)); // ERC-4906
        assertFalse(art.supportsInterface(0xffffffff));
        vm.startPrank(ALICE);
        vm.expectRevert(LineageArtwork.WalletBound.selector); art.approve(BOB, id);
        vm.expectRevert(LineageArtwork.WalletBound.selector); art.setApprovalForAll(BOB, true);
        vm.expectRevert(LineageArtwork.WalletBound.selector); art.transferFrom(ALICE, BOB, id);
        vm.expectRevert(LineageArtwork.WalletBound.selector); art.safeTransferFrom(ALICE, BOB, id);
        vm.expectRevert(LineageArtwork.WalletBound.selector); art.safeTransferFrom(ALICE, BOB, id, "");
        vm.stopPrank();
        vm.expectRevert(LineageArtwork.OnlyToken.selector); art.balanceChanged(ALICE, BOB);
    }

    /// @dev The JSON log is also used to render a local contact sheet from actual tokenURI output.
    function testExportMarketplaceStates() public {
        uint256 first = release(0);
        emit log_named_string("funded", art.tokenURI(art.tokenIdOf(ALICE)));
        vm.prank(ALICE); token.transfer(BOB, first);
        uint256 second = release(1);
        vm.prank(ALICE); token.transfer(BOB, second);
        emit log_named_string("mixed", art.tokenURI(art.tokenIdOf(BOB)));
        assertEq(art.svg(art.tokenIdOf(BOB)), token.renderer().drawTokenBalance(first + second, token.inkOf(BOB)));
        vm.prank(BOB); token.transfer(ALICE, 1);
        emit log_named_string("dust", art.tokenURI(art.tokenIdOf(ALICE)));
        assertEq(vm.parseJsonString(metadata(ALICE), string.concat(trait(metadata(ALICE), "Balance"), ".value")), "0.000000000000000001");
        vm.prank(ALICE); token.transfer(BOB, 1);
        emit log_named_string("zero", art.tokenURI(art.tokenIdOf(ALICE)));
        uint256[4] memory weights = [uint256(1), 2, 3, 4];
        emit log_named_string("maximum-svg", token.renderer().drawTokenBalance(token.maxSupply(), weights));
    }

    function testExportFullScaleRendererGallery() public {
        uint256[12] memory amounts = [uint256(0), 1, 1e16-1, 1e16, 1e18, 10e18, 1000e18, 10000e18, 1000000e18, 10000000e18, 53750000e18, token.maxSupply()];
        uint256[4] memory mixed = [uint256(1), 2, 3, 4];
        for (uint256 i; i < amounts.length; i++) {
            string memory image = token.renderer().drawTokenBalance(amounts[i], mixed);
            assertTrue(contains(image, "</svg>"));
            emit log_named_string(string.concat("scale-", vm.toString(amounts[i]), "-mixed"), image);
        }
        assertEq(token.renderer().displayTokenBalance(53750000e18), "53,750,000.00");
        assertEq(token.renderer().displayTokenBalance(token.maxSupply()), "53,752,386.70");
        for (uint256 c; c < 4; c++) {
            uint256[4] memory pureInk;
            pureInk[c] = 1;
            emit log_named_string(string.concat("scale-53750000000000000000000000-", vm.toString(c)), token.renderer().drawTokenBalance(53750000e18, pureInk));
        }
    }

    function contains(string memory text, string memory fragment) internal pure returns (bool) {
        bytes memory a = bytes(text); bytes memory b = bytes(fragment);
        for (uint256 i; i + b.length <= a.length; ++i) {
            bool match_ = true;
            for (uint256 j; j < b.length; ++j) if (a[i + j] != b[j]) { match_ = false; break; }
            if (match_) return true;
        }
        return false;
    }
}
