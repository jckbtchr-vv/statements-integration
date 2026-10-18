// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Credits} from "../src/Credits.sol";
import {Statements} from "../src/Statements.sol";
import {Withdrawals} from "../src/Withdrawals.sol";
import {BalanceArtwork} from "../src/BalanceArtwork.sol";
import {WithdrawnRenderer} from "../src/renderers/WithdrawnRenderer.sol";

contract InitialTestRenderer {
    function svg(uint256) external pure returns (string memory) {
        return '<svg xmlns="http://www.w3.org/2000/svg"/>';
    }

    function html(uint256) external pure returns (string memory) {
        return "";
    }
}

contract WithdrawalsFixture is Test {
    Credits internal credits;
    Statements internal statements;
    Withdrawals internal withdrawals;
    BalanceArtwork internal artwork;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant MALLORY = address(0xBAD);

    function setUp() public virtual {
        vm.warp(1_790_100_000);
        credits = new Credits(address(this));
        statements = new Statements(address(this), address(credits), 0);
        statements.addFormat(address(new InitialTestRenderer()), "Issued");
        address[] memory owners = new address[](640);
        bytes21[] memory seeds = new bytes21[](640);
        uint64[] memory timestamps = new uint64[](640);
        for (uint256 i; i < 640; ++i) {
            owners[i] = ALICE;
            bytes memory raw = new bytes(21);
            raw[0] = "A";
            for (uint256 j = 1; j < 21; ++j) {
                uint256 digit = ((i + 1) / (10 ** (20 - j))) % 10;
                raw[j] = bytes1(uint8(digit < 8 ? 48 + digit : 97 + digit - 8));
            }
            seeds[i] = bytes21(raw);
            timestamps[i] = uint64(1_790_000_000 + i);
        }
        credits.distribute(owners, seeds, timestamps);
        credits.seal();
        withdrawals = new Withdrawals(address(statements), 1);
        statements.addFormat(address(withdrawals.renderer()), "Withdrawn");
        artwork = withdrawals.artwork();
        vm.prank(ALICE);
        credits.setApprovalForAll(address(statements), true);
    }

    function compose(uint256 page) internal returns (uint256 id) {
        uint256[80] memory ids;
        for (uint256 i; i < 80; ++i) {
            ids[i] = page * 80 + i + 1;
        }
        vm.prank(ALICE);
        id = statements.compose(ids, 0);
    }

    function take(uint256 id) internal returns (uint256 amount) {
        amount = withdrawals.quote(id);
        vm.startPrank(ALICE);
        statements.approve(address(withdrawals), id);
        withdrawals.withdraw(id, amount);
        vm.stopPrank();
    }
}

contract WithdrawalsTest is WithdrawalsFixture {
    function test_fullSupplyExistsOnlyInReserveAtDeployment() public view {
        assertEq(withdrawals.maxSupply(), 537_523_867_072);
        assertEq(withdrawals.totalSupply(), withdrawals.maxSupply());
        assertEq(withdrawals.balanceOf(address(withdrawals)), withdrawals.maxSupply());
        assertEq(withdrawals.unreleasedSupply(), withdrawals.maxSupply());
        assertEq(withdrawals.totalReleased(), 0);
        assertEq(withdrawals.balanceOf(address(this)), 0);
        assertEq(withdrawals.balanceOf(ALICE), 0);
    }

    function test_withdrawalTransfersReserveWithoutMinting() public {
        uint256 id = compose(0);
        vm.recordLogs();
        uint256 amount = take(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 releases;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(withdrawals) || logs[i].topics[0] != keccak256("Transfer(address,address,uint256)")) continue;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), address(withdrawals));
            assertEq(address(uint160(uint256(logs[i].topics[2]))), ALICE);
            assertEq(abi.decode(logs[i].data, (uint256)), amount);
            ++releases;
        }
        assertEq(releases, 1);
        assertEq(withdrawals.totalSupply(), withdrawals.maxSupply());
        assertEq(withdrawals.unreleasedSupply(), withdrawals.maxSupply() - amount);
        assertEq(withdrawals.balanceOf(address(withdrawals)), withdrawals.unreleasedSupply());
    }

    function test_returnedTokensStayLockedWithoutRestoringAllocation() public {
        uint256 first = compose(0);
        uint256 second = compose(1);
        // Artificially exhaust the allocation to exercise the hard bound independently
        // of the real collection, whose exact rating is below it after the remainder.
        vm.mockCall(address(statements), abi.encodeCall(statements.creditScoreOf, (first)), abi.encode(withdrawals.maxSupply()));
        take(first);
        vm.prank(ALICE);
        withdrawals.transfer(address(withdrawals), 10_000);
        assertEq(withdrawals.totalReleased(), withdrawals.maxSupply());
        assertEq(withdrawals.unreleasedSupply(), 0);
        assertEq(withdrawals.balanceOf(address(withdrawals)), 10_000);
        vm.startPrank(ALICE);
        statements.approve(address(withdrawals), second);
        uint256 nextScore = statements.creditScoreOf(second);
        vm.expectRevert(Withdrawals.SupplyExceeded.selector);
        withdrawals.withdraw(second, nextScore);
        vm.stopPrank();
        assertEq(statements.ownerOf(second), ALICE);
        (address holder,) = withdrawals.receipts(second);
        assertEq(holder, address(0));
    }

    function test_reserveHasNoAllowanceOrRecoveryPath() public {
        address[3] memory callers = [ALICE, address(this), MALLORY];
        for (uint256 i; i < callers.length; ++i) {
            assertEq(withdrawals.allowance(address(withdrawals), callers[i]), 0);
            vm.startPrank(callers[i]);
            vm.expectRevert();
            withdrawals.transferFrom(address(withdrawals), callers[i], 1);
            (bool ok,) = address(withdrawals).call(abi.encodeWithSignature("rescue(address,uint256)", callers[i], 1));
            assertFalse(ok);
            (ok,) = address(withdrawals).call(abi.encodeWithSignature("burn(uint256)", 1));
            assertFalse(ok);
            vm.stopPrank();
        }
        assertEq(withdrawals.balanceOf(address(withdrawals)), withdrawals.maxSupply());
    }

    function test_atomicWithdrawalExactScoreAndMetadata() public {
        uint256 id = compose(0);
        uint256 score = statements.creditScoreOf(id);
        uint256 beforeGas = gasleft();
        take(id);
        emit log_named_uint("approve and withdraw gas", beforeGas - gasleft());
        assertEq(withdrawals.decimals(), 4);
        assertEq(withdrawals.name(), "Balances");
        assertEq(withdrawals.symbol(), "BALANCE");
        assertEq(artwork.name(), "Balances");
        assertEq(withdrawals.balanceOf(ALICE), score);
        assertEq(withdrawals.totalSupply(), withdrawals.maxSupply());
        assertEq(withdrawals.totalReleased(), score);
        assertEq(withdrawals.withdrawnCount(), 1);
        assertEq(statements.ownerOf(id), address(withdrawals));
        assertEq(statements.formatOf(id), 1);
        assertEq(statements.getApproved(id), address(0));
        (address holder, uint256 amount) = withdrawals.receipts(id);
        assertEq(holder, ALICE);
        assertEq(amount, score);
        assertEq(
            statements.statementSVG(id),
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 76 95"><rect width="76" height="95" fill="#ffffff"/></svg>'
        );
        assertEq(statements.creditScoreOf(id), score);
        assertEq(statements.composedFrom(id)[0], 1);
    }

    function test_cannotWithdrawTwiceOrQuoteLocked() public {
        uint256 id = compose(0);
        take(id);
        vm.expectRevert(Withdrawals.AlreadyWithdrawn.selector);
        withdrawals.quote(id);
        vm.prank(ALICE);
        vm.expectRevert(Withdrawals.NotStatementOwner.selector);
        withdrawals.withdraw(id, 0);
    }

    function test_approvedOperatorCannotTakeOwnersScore() public {
        uint256 id = compose(0);
        uint256 score = statements.creditScoreOf(id);
        vm.prank(ALICE);
        statements.setApprovalForAll(MALLORY, true);
        vm.prank(MALLORY);
        vm.expectRevert(Withdrawals.NotStatementOwner.selector);
        withdrawals.withdraw(id, score);
        assertEq(withdrawals.totalSupply(), withdrawals.maxSupply());
        assertEq(withdrawals.totalReleased(), 0);
        assertEq(statements.ownerOf(id), ALICE);
    }

    function test_singleTokenApprovalCannotAffectOtherStatements() public {
        uint256 first = compose(0);
        uint256 second = compose(1);
        take(first);
        uint256 score = statements.creditScoreOf(second);
        vm.prank(ALICE);
        vm.expectRevert();
        withdrawals.withdraw(second, score);
        assertEq(statements.ownerOf(second), ALICE);
    }

    function test_missingApprovalRollsBackReceiptAndSupply() public {
        uint256 id = compose(0);
        uint256 amount = withdrawals.quote(id);
        vm.prank(ALICE);
        vm.expectRevert();
        withdrawals.withdraw(id, amount);
        (address holder,) = withdrawals.receipts(id);
        assertEq(holder, address(0));
        assertEq(withdrawals.withdrawnCount(), 0);
        assertEq(withdrawals.totalSupply(), withdrawals.maxSupply());
        assertEq(withdrawals.totalReleased(), 0);
        assertEq(statements.formatOf(id), 0);
    }

    function test_staleQuoteAfterOverprintRequiresNewReview() public {
        uint256 id = compose(0);
        uint256 top = compose(1);
        uint256 old = withdrawals.quote(id);
        vm.startPrank(ALICE);
        statements.overprint(id, top);
        statements.approve(address(withdrawals), id);
        uint256 changed = statements.creditScoreOf(id);
        vm.expectRevert(abi.encodeWithSelector(Withdrawals.ScoreChanged.selector, changed));
        withdrawals.withdraw(id, old);
        withdrawals.withdraw(id, changed);
        vm.stopPrank();
        assertEq(withdrawals.balanceOf(ALICE), changed);
        vm.expectRevert();
        withdrawals.quote(top);
    }

    function test_eightPageBlackStatementTurnsWhiteAllScoreIssued() public {
        uint256 base = compose(0);
        uint256 total = statements.creditScoreOf(base);
        for (uint256 i = 1; i < 8; ++i) {
            uint256 top = compose(i);
            total += statements.creditScoreOf(top);
            vm.prank(ALICE);
            statements.overprint(base, top);
        }
        assertEq(statements.overprintsOf(base), 7);
        uint256 beforeGas = gasleft();
        take(base);
        emit log_named_uint("eight-page approve and withdrawal gas", beforeGas - gasleft());
        assertEq(withdrawals.balanceOf(ALICE), total);
        assertEq(
            statements.statementSVG(base),
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 76 95"><rect width="76" height="95" fill="#ffffff"/></svg>'
        );
        assertEq(statements.historyLength(base), 8);
    }

    function test_formerOwnerAndCollectionOwnerCannotReleaseOrModify() public {
        uint256 id = compose(0);
        uint256 other = compose(1);
        take(id);
        address[3] memory callers = [ALICE, address(this), MALLORY];
        for (uint256 i; i < callers.length; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert();
            statements.transferFrom(address(withdrawals), callers[i], id);
            vm.expectRevert();
            statements.setFormat(id, 0);
            vm.expectRevert();
            statements.approve(callers[i], id);
            vm.expectRevert();
            statements.overprint(other, id);
            vm.expectRevert();
            statements.overprint(id, other);
            (bool ok,) = address(withdrawals).call(abi.encodeWithSignature("rescue(uint256)", id));
            assertFalse(ok);
            (ok,) = address(withdrawals).call(abi.encodeWithSignature("mint(address,uint256)", callers[i], 1));
            assertFalse(ok);
            vm.stopPrank();
        }
    }

    function test_unregisteredOrWrongRendererFailsClosed() public {
        Withdrawals pending = new Withdrawals(address(statements), 2);
        uint256 id = compose(0);
        uint256 score = statements.creditScoreOf(id);
        assertFalse(pending.ready());
        vm.startPrank(ALICE);
        statements.approve(address(pending), id);
        vm.expectRevert(Withdrawals.RendererNotRegistered.selector);
        pending.withdraw(id, score);
        vm.stopPrank();
        statements.addFormat(address(new InitialTestRenderer()), "Different");
        assertFalse(pending.ready());
        assertEq(statements.ownerOf(id), ALICE);
    }

    function test_registrySealingAfterRegistrationDoesNotDisableWithdrawals() public {
        statements.seal();
        assertTrue(withdrawals.ready());
        take(compose(0));
    }

    function test_whiteFormatAloneDoesNotIssueOrLock() public {
        uint256 id = compose(0);
        vm.prank(ALICE);
        statements.setFormat(id, 1);
        assertEq(statements.ownerOf(id), ALICE);
        assertEq(withdrawals.totalSupply(), withdrawals.maxSupply());
        assertEq(withdrawals.totalReleased(), 0);
        vm.prank(ALICE);
        statements.setFormat(id, 0);
        take(id);
    }

    function test_unsolicitedSafeTransfersAndSpoofedCallbacksRejected() public {
        uint256 id = compose(0);
        vm.prank(ALICE);
        vm.expectRevert(Withdrawals.UnexpectedNFT.selector);
        statements.safeTransferFrom(ALICE, address(withdrawals), id);
        vm.expectRevert(Withdrawals.UnexpectedNFT.selector);
        withdrawals.onERC721Received(address(withdrawals), ALICE, id, "");
        assertEq(statements.ownerOf(id), ALICE);
    }

    function test_rawTransferIsUnrecoverableAndDoesNotIssue() public {
        uint256 id = compose(0);
        vm.prank(ALICE);
        statements.transferFrom(ALICE, address(withdrawals), id);
        assertEq(statements.ownerOf(id), address(withdrawals));
        assertEq(withdrawals.totalSupply(), withdrawals.maxSupply());
        assertEq(withdrawals.totalReleased(), 0);
        vm.expectRevert(Withdrawals.AlreadyWithdrawn.selector);
        withdrawals.quote(id);
    }

    function test_unknownAndBurnedStatementsDoNotQuote() public {
        vm.expectRevert();
        withdrawals.quote(0);
        vm.expectRevert();
        withdrawals.quote(500);
        uint256 base = compose(0);
        uint256 top = compose(1);
        vm.prank(ALICE);
        statements.overprint(base, top);
        assertGt(statements.creditScoreOf(top), 0);
        vm.expectRevert();
        withdrawals.quote(top);
    }

    function test_invalidSourcesRejected() public {
        vm.expectRevert(Withdrawals.InvalidSource.selector);
        new Withdrawals(address(0), 0);
        Credits unsealed = new Credits(address(this));
        Statements other = new Statements(address(this), address(unsealed), 0);
        vm.expectRevert(Withdrawals.InvalidSource.selector);
        new Withdrawals(address(other), 0);
    }

    function test_capAndZeroScoreEnforced() public {
        uint256 id = compose(0);
        assertEq(withdrawals.maxSupply(), 537_523_867_072);
        vm.mockCall(address(statements), abi.encodeCall(statements.creditScoreOf, (id)), abi.encode(uint256(0)));
        vm.expectRevert(Withdrawals.InvalidScore.selector);
        withdrawals.quote(id);
        vm.mockCall(
            address(statements), abi.encodeCall(statements.creditScoreOf, (id)), abi.encode(withdrawals.maxSupply() + 1)
        );
        vm.expectRevert(Withdrawals.InvalidScore.selector);
        withdrawals.quote(id);
    }

    function testFuzz_transfersAndAllowanceConserveSupply(uint256 value) public {
        uint256 id = compose(0);
        uint256 score = take(id);
        uint256 amount = bound(value, 0, score);
        vm.prank(ALICE);
        withdrawals.approve(MALLORY, amount);
        vm.prank(MALLORY);
        withdrawals.transferFrom(ALICE, BOB, amount);
        assertEq(withdrawals.balanceOf(ALICE) + withdrawals.balanceOf(BOB), score);
        assertEq(withdrawals.totalSupply(), withdrawals.maxSupply());
        assertEq(withdrawals.totalReleased(), score);
        assertEq(withdrawals.allowance(ALICE, MALLORY), 0);
        vm.prank(MALLORY);
        vm.expectRevert();
        withdrawals.transferFrom(ALICE, MALLORY, 1);
    }
}

contract BalanceArtworkTest is WithdrawalsFixture {
    function test_firstBaseUnitAutomaticallyCreatesArtworkWithoutStatement() public {
        take(compose(0));
        assertEq(statements.balanceOf(BOB), 0);
        vm.prank(ALICE);
        withdrawals.transfer(BOB, 1);
        uint256 id = artwork.tokenIdOf(BOB);
        assertEq(artwork.ownerOf(id), BOB);
        assertEq(artwork.displayBalance(BOB), "0.0001");
        assertEq(artwork.artworkBalance(BOB), "0");
        vm.prank(BOB);
        withdrawals.transfer(ALICE, 1);
        assertEq(artwork.ownerOf(id), BOB);
        assertEq(artwork.totalSupply(), 2);
        vm.prank(ALICE);
        withdrawals.transfer(BOB, 1);
        assertEq(artwork.tokenIdOf(BOB), id);
        assertEq(artwork.totalSupply(), 2);
    }

    function test_galleryEnumeratesRecipientsAndRetainsZero() public {
        uint256 amount = take(compose(0));
        vm.prank(ALICE);
        withdrawals.transfer(BOB, amount);
        assertEq(artwork.totalSupply(), 2);
        assertEq(artwork.wallets(0), ALICE);
        assertEq(artwork.wallets(1), BOB);
        (address[] memory owners, uint256[] memory values) = artwork.balances(0, 64);
        assertEq(owners.length, 2);
        assertEq(owners[0], ALICE);
        assertEq(owners[1], BOB);
        assertEq(values[0], 0);
        assertEq(values[1], amount);
        vm.prank(BOB);
        withdrawals.transfer(ALICE, 1);
        (owners, values) = artwork.balances(0, 1);
        assertEq(owners.length, 1);
        assertEq(values[0], 1);
        (owners, values) = artwork.balances(1, 1);
        assertEq(owners[0], BOB);
        assertEq(values[0], amount - 1);
    }

    function test_galleryPaginationIsBoundedAndHandlesEmptyRanges() public {
        (address[] memory owners, uint256[] memory values) = artwork.balances(type(uint256).max, 64);
        assertEq(owners.length, 0);
        assertEq(values.length, 0);
        (owners, values) = artwork.balances(0, 0);
        assertEq(owners.length, 0);
        vm.expectRevert(BalanceArtwork.PageTooLarge.selector);
        artwork.balances(0, 65);
    }

    function test_contractRecipientCannotRejectOrReenterTokenTransferThroughNFT() public {
        take(compose(0));
        RejectArtwork receiver = new RejectArtwork();
        vm.prank(ALICE);
        withdrawals.transfer(address(receiver), 10_000);
        assertEq(withdrawals.balanceOf(address(receiver)), 10_000);
        assertEq(artwork.balanceOf(address(receiver)), 1);
        assertEq(artwork.ownerOf(artwork.tokenIdOf(address(receiver))), address(receiver));
        receiver.send(withdrawals, BOB, 10_000);
        assertEq(artwork.artworkBalance(address(receiver)), "0");
        assertEq(artwork.balanceOf(address(receiver)), 1);
        assertEq(artwork.balanceOf(BOB), 1);
    }

    function test_withdrawalAutomaticallyIssuesOneAndPersistsAtZero() public {
        take(compose(0));
        uint256 id = artwork.tokenIdOf(ALICE);
        assertEq(id, uint256(uint160(ALICE)));
        assertEq(artwork.ownerOf(id), ALICE);
        assertTrue(artwork.locked(id));
        uint256 amount = withdrawals.balanceOf(ALICE);
        vm.prank(ALICE);
        withdrawals.transfer(BOB, amount);
        assertEq(artwork.balanceOf(ALICE), 1);
        assertEq(artwork.artworkBalance(ALICE), "0");
        assertGt(bytes(artwork.tokenURI(id)).length, 100);
    }

    function test_zeroTransfersAndReserveNeverCreateArtwork() public {
        assertEq(artwork.totalSupply(), 0);
        assertEq(artwork.tokenIdOf(address(withdrawals)), 0);
        vm.prank(ALICE);
        withdrawals.transfer(BOB, 0);
        assertEq(artwork.totalSupply(), 0);
        uint256 amount = take(compose(0));
        vm.prank(ALICE);
        withdrawals.transfer(address(withdrawals), amount);
        assertEq(artwork.totalSupply(), 1);
        assertEq(artwork.tokenIdOf(address(withdrawals)), 0);
        vm.expectRevert();
        artwork.locked(123);
        vm.expectRevert();
        artwork.tokenURI(123);
        vm.expectRevert();
        artwork.svg(123);
    }

    function test_allNFTTransferAndApprovalPathsRevert() public {
        take(compose(0));
        uint256 id = artwork.tokenIdOf(ALICE);
        vm.startPrank(ALICE);
        vm.expectRevert(BalanceArtwork.WalletBound.selector);
        artwork.transferFrom(ALICE, BOB, id);
        vm.expectRevert(BalanceArtwork.WalletBound.selector);
        artwork.transferFrom(ALICE, ALICE, id);
        vm.expectRevert(BalanceArtwork.WalletBound.selector);
        artwork.safeTransferFrom(ALICE, BOB, id);
        vm.expectRevert(BalanceArtwork.WalletBound.selector);
        artwork.safeTransferFrom(ALICE, BOB, id, "");
        vm.expectRevert(BalanceArtwork.WalletBound.selector);
        artwork.approve(BOB, id);
        vm.expectRevert(BalanceArtwork.WalletBound.selector);
        artwork.setApprovalForAll(BOB, true);
        vm.stopPrank();
    }

    function test_interfacesAndRestrictedMetadataEvents() public {
        assertTrue(artwork.supportsInterface(0x80ac58cd));
        assertTrue(artwork.supportsInterface(0x5b5e139f));
        assertTrue(artwork.supportsInterface(0xb45a3c0e));
        assertTrue(artwork.supportsInterface(0x49064906));
        assertFalse(artwork.supportsInterface(0xffffffff));
        vm.expectRevert(BalanceArtwork.OnlyToken.selector);
        artwork.balanceChanged(ALICE, BOB);
        take(compose(0));
        uint256 id = artwork.tokenIdOf(ALICE);
        vm.recordLogs();
        vm.prank(ALICE);
        withdrawals.transfer(BOB, 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 5); // ERC20 transfer; sender refresh; NFT mint, lock, recipient refresh.
        assertEq(logs[1].emitter, address(artwork));
        assertEq(logs[1].topics[0], keccak256("MetadataUpdate(uint256)"));
        assertEq(abi.decode(logs[1].data, (uint256)), id);
        assertEq(logs[2].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(logs[3].topics[0], keccak256("Locked(uint256)"));
        vm.recordLogs();
        vm.prank(ALICE);
        withdrawals.transfer(ALICE, 0);
        assertEq(vm.getRecordedLogs().length, 1);
    }

    function test_firstReceiptGasAndLaterReceiptGas() public {
        take(compose(0));
        vm.startPrank(ALICE);
        uint256 beforeGas = gasleft();
        withdrawals.transfer(BOB, 10_000);
        emit log_named_uint("first receipt gas including artwork", beforeGas - gasleft());
        beforeGas = gasleft();
        withdrawals.transfer(BOB, 1);
        emit log_named_uint("repeat receipt gas in same transaction", beforeGas - gasleft());
        vm.stopPrank();
        assertEq(artwork.totalSupply(), 2);
    }

    function test_exactFractionalFormatting() public {
        take(compose(0));
        uint256[7] memory amounts = [uint256(0), 1, 10, 1000, 10_000, 10_001, 364_212_480];
        string[7] memory labels = ["0", "0.0001", "0.001", "0.1", "1", "1.0001", "36,421.248"];
        for (uint256 i; i < amounts.length; ++i) {
            vm.mockCall(address(withdrawals), abi.encodeCall(withdrawals.balanceOf, (BOB)), abi.encode(amounts[i]));
            assertEq(artwork.displayBalance(BOB), labels[i]);
        }
    }

    function test_artworkTruncatesToTwoDecimalsWithoutChangingUnits() public {
        uint256[10] memory amounts = [uint256(0), 1, 99, 100, 199, 9999, 10000, 10999, 1508155218, 976639999999];
        string[10] memory labels = ["0", "0", "0", "0.01", "0.01", "0.99", "1", "1.09", "150,815.52", "97,663,999.99"];
        for (uint256 i; i < amounts.length; ++i) {
            vm.mockCall(address(withdrawals), abi.encodeCall(withdrawals.balanceOf, (BOB)), abi.encode(amounts[i]));
            assertEq(artwork.artworkBalance(BOB), labels[i]);
            assertEq(withdrawals.balanceOf(BOB), amounts[i]);
        }
        assertEq(artwork.displayBalance(BOB), "97,663,999.9999");
    }

    function test_pixelArtworkMatchesPreviewAtZeroFractionsAndMaximum() public {
        take(compose(0));
        uint256 id = artwork.tokenIdOf(ALICE);
        string memory fixtures = vm.readFile("test/fixtures/balance-pixels.json");
        for (uint256 i; i < 12; ++i) {
            string memory key = string.concat(".[", vm.toString(i), "]");
            uint256 amount = vm.parseUint(vm.parseJsonString(fixtures, string.concat(key, ".amount")));
            vm.mockCall(address(withdrawals), abi.encodeCall(withdrawals.balanceOf, (ALICE)), abi.encode(amount));
            assertEq(artwork.artworkBalance(ALICE), vm.parseJsonString(fixtures, string.concat(key, ".label")));
            assertEq(artwork.svg(id), vm.parseJsonString(fixtures, string.concat(key, ".svg")));
        }
    }

 }

// Rejects ERC-721 callbacks outright. It can still receive/send BALANCE like a pool or smart wallet.
contract RejectArtwork is IERC721Receiver {
    function send(Withdrawals token, address to, uint256 amount) external { token.transfer(to, amount); }
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        revert("No NFT callbacks allowed");
    }
}
