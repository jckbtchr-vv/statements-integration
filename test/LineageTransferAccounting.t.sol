// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {WithdrawalsFixture} from "./Withdrawals.t.sol";
import {LineageWithdrawals} from "../src/experimental/LineageWithdrawals.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";

/// Independent, unpacked history ledger checks the optimized storage representation.
contract LineageTransferAccountingTest is WithdrawalsFixture {
    using stdStorage for StdStorage;
    LineageWithdrawals internal token;
    mapping(address => LineageWithdrawals.History) internal expected;
    mapping(address => uint256) internal amounts;
    address[4] internal actors;
    function setUp() public override {
        super.setUp();
        token = new LineageWithdrawals(address(statements), 2);
        statements.addFormat(address(token.renderer()), "Balance");
        actors = [ALICE, BOB, MALLORY, address(token)];
        amounts[address(token)] = token.maxSupply();
    }
    function record(address from, address to, uint256 value, bool isRelease) internal {
        if (from == to || value == 0) return;
        uint256 beforeTo = amounts[to];
        amounts[from] -= value;
        amounts[to] += value;
        if (!isRelease) {
            expected[from].sent += value;
            ++expected[from].transfersOut;
            if (amounts[from] == 0) ++expected[from].emptied;
        } else {
            expected[to].contributed += value;
            ++expected[to].statementsSurrendered;
        }
        LineageWithdrawals.History storage h = expected[to];
        if (h.received == 0) h.firstReceipt = block.timestamp;
        else if (beforeTo == 0) ++h.returnsFromZero;
        h.received += value;
        if (!isRelease) ++h.transfersIn;
        if (amounts[to] > h.peak) h.peak = amounts[to];
    }
    function release(uint256 page) internal returns (uint256 amount) {
        uint256 id = compose(page);
        amount = token.quote(id);
        vm.startPrank(ALICE);
        statements.approve(address(token), id);
        token.withdraw(id, amount);
        vm.stopPrank();
        record(address(token), ALICE, amount, true);
    }
    function move(address from, address to, uint256 n, bool delegated) internal {
        if (delegated) {
            vm.prank(from); token.approve(address(this), n);
            token.transferFrom(from, to, n);
        } else { vm.prank(from); token.transfer(to, n); }
        record(from, to, n, false);
    }
    function compare() internal view {
        for (uint256 i; i < actors.length; ++i) {
            address who = actors[i];
            assertEq(token.balanceOf(who), amounts[who]);
            bytes memory want = abi.encode(expected[who]);
            assertEq(abi.encode(token.historyOf(who)), want, "historyOf differs from reference ledger");
            (bool ok, bytes memory got) = address(token).staticcall(abi.encodeWithSignature("history(address)", who));
            assertTrue(ok);
            assertEq(got, want, "legacy getter ABI or values changed");
        }
    }
    function testFuzzPackedHistoryMatchesReference(uint256 seed) public {
        release(0); compare();
        for (uint256 step; step < 96; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            if (step == 32 || step == 64) release(step / 32);
            address from = actors[seed % 3];
            address to = actors[(seed >> 8) % 4];
            uint256 balance = amounts[from];
            uint256 n = step % 5 == 0 ? balance : (seed >> 16) % (balance + 1);
            if (step % 7 == 0) n = 0;
            move(from, to, n, step % 2 == 0);
            vm.warp(block.timestamp + 1);
            compare();
        }
    }
    function testZeroTimestampAndReturnsDoNotResetFirstReceipt() public {
        vm.warp(0); uint256 amount = release(0);
        move(ALICE, BOB, amount, false);
        vm.warp(50);
        move(BOB, ALICE, amount, false);
        move(ALICE, address(token), amount / 2, false);
        release(1); compare();
        assertEq(token.historyOf(ALICE).firstReceipt, 0);
        assertEq(token.historyOf(address(token)).received, amount / 2);
    }
    function testSupplyBoundFitsChannelsAndHistoryAmounts() public {
        uint256 id = compose(0);
        uint256 supply = token.maxSupply();
        assertLt(supply, 2 ** 86);
        vm.mockCall(address(statements), abi.encodeWithSignature("creditScoreOf(uint256)", id), abi.encode(supply / 1e14));
        uint256[240] memory words; words[0] = 8; // entire reserve in black
        vm.mockCall(address(statements), abi.encodeWithSignature("inkOf(uint256)", id), abi.encode(words));
        vm.startPrank(ALICE); statements.approve(address(token), id); token.withdraw(id, supply); vm.stopPrank();
        record(address(token), ALICE, supply, true);
        move(ALICE, BOB, supply, true);
        move(BOB, MALLORY, supply - 1, false);
        assertEq(token.inkOf(MALLORY)[3], supply - 1);
        assertEq(token.inkOf(BOB)[3], 1);
        compare();
    }
    function testCumulativeTurnoverRemainsFullWidth() public {
        release(0);
        stdstore.target(address(token)).sig("history(address)").with_key(BOB).depth(2).checked_write(type(uint128).max);
        vm.prank(ALICE); token.transfer(BOB, 1 ether);
        assertEq(token.historyOf(BOB).sent, type(uint128).max);
        assertEq(token.historyOf(BOB).received, uint256(type(uint128).max) + 1 ether);
    }
    function testReceivedTurnoverOverflowStillRevertsAtomically() public {
        release(0);
        stdstore.target(address(token)).sig("history(address)").with_key(BOB).depth(2).checked_write(type(uint256).max);
        uint256 beforeBalance = token.balanceOf(ALICE);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        vm.prank(ALICE); token.transfer(BOB, 1);
        assertEq(token.balanceOf(ALICE), beforeBalance);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.historyOf(BOB).received, type(uint256).max);
        assertEq(token.artwork().tokenIdOf(BOB), 0);
    }
    function testPackedCounterOverflowRevertsWithoutAffectingNeighborsOrFunds() public {
        release(0);
        stdstore.enable_packed_slots().target(address(token)).sig("history(address)").with_key(ALICE).depth(4).checked_write(type(uint64).max);
        bytes memory beforeHistory = abi.encode(token.historyOf(ALICE));
        bytes memory beforeInk = abi.encode(token.inkOf(ALICE));
        uint256 beforeBalance = token.balanceOf(ALICE);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        vm.prank(ALICE); token.transfer(BOB, 1);
        assertEq(abi.encode(token.historyOf(ALICE)), beforeHistory);
        assertEq(abi.encode(token.inkOf(ALICE)), beforeInk);
        assertEq(token.balanceOf(ALICE), beforeBalance);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.artwork().tokenIdOf(BOB), 0);
    }
}
