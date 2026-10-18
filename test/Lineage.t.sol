// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {WithdrawalsFixture} from "./Withdrawals.t.sol";
import {LineageArtwork} from "../src/experimental/LineageArtwork.sol";
import {InkMath} from "../src/experimental/InkMath.sol";
import {LineageWithdrawals} from "../src/experimental/LineageWithdrawals.sol";

contract InkMathTest is Test {
    function testMainnetSnapshotMatchesReferenceCounts() public {
        string memory json=vm.readFile("test/fixtures/lineage-mainnet.json");
        for(uint256 i;i<3;++i){
            string memory base=string.concat(".sources[",vm.toString(i),"]");
            string[] memory raw=vm.parseJsonStringArray(json,string.concat(base,".words"));
            string[] memory expected=vm.parseJsonStringArray(json,string.concat(base,".weights"));
            uint256[240] memory words;
            for(uint256 w;w<240;++w)words[w]=vm.parseUint(raw[w]);
            uint256[4] memory actual=InkMath.count(words);
            for(uint256 c;c<4;++c)assertEq(actual[c],vm.parseUint(expected[c]));
        }
    }
    function testCountMasksAndIgnoresPadding() public pure {
        uint256[240] memory words;
        words[0] = 0xf321; // C, M, C+M, C+M+Y+K
        words[2] = type(uint256).max; // only 16 real pixels
        uint256[4] memory v = InkMath.count(words);
        assertEq(v[0],19);assertEq(v[1],19);assertEq(v[2],17);assertEq(v[3],17);
    }
    function testFuzzCountAgainstNaive(uint256 w0,uint256 w1,uint256 w2) public pure {
        uint256[240] memory words;words[0]=w0;words[1]=w1;words[2]=w2;
        uint256[4] memory expected;
        for(uint256 p;p<144;++p) for(uint256 c;c<4;++c) expected[c]+=(words[p/64]>>((p%64)*4+c))&1;
        assertEq(abi.encode(InkMath.count(words)),abi.encode(expected));
    }
    function testFuzzSplitConserves(uint64 c,uint64 m,uint64 y,uint64 k,uint256 input) public pure {
        uint256[4] memory weights=[uint256(c),m,y,k];uint256 sum=InkMath.sum(weights);
        if(sum==0)return;
        uint256 amount=input%(sum+1);
        uint256[4] memory moved=InkMath.split(amount,weights);
        assertEq(InkMath.sum(moved),amount);
        for(uint256 i;i<4;++i)assertLe(moved[i],weights[i]);
    }
}

contract LineageTest is WithdrawalsFixture {
    LineageWithdrawals internal token;
    function setUp() public override {
        super.setUp();
        token=new LineageWithdrawals(address(statements),2);
        statements.addFormat(address(token.renderer()),"Withdrawn lineage study");
    }
    function release(uint256 page) internal returns(uint256 id,uint256 amount) {
        id=compose(page);amount=token.quote(id);
        vm.startPrank(ALICE);statements.approve(address(token),id);token.withdraw(id,amount);vm.stopPrank();
    }
    function testUnsolicitedSafeTransferRejectedThenWithdrawalSucceeds() public {
        uint256 id = compose(0);
        uint256 amount = token.quote(id);
        vm.prank(ALICE);
        vm.expectRevert(LineageWithdrawals.UnexpectedNFT.selector);
        statements.safeTransferFrom(ALICE, address(token), id);
        assertEq(statements.ownerOf(id), ALICE);
        assertEq(token.totalReleased(), 0);
        assertEq(token.withdrawnCount(), 0);
        (address holder, uint256 issued) = token.receipts(id);
        assertEq(holder, address(0));
        assertEq(issued, 0);
        vm.startPrank(ALICE);
        statements.approve(address(token), id);
        token.withdraw(id, amount);
        vm.stopPrank();
        assertEq(statements.ownerOf(id), address(token));
        assertEq(token.balanceOf(ALICE), amount);
        vm.prank(ALICE);
        vm.expectRevert();
        statements.transferFrom(address(token), ALICE, id);
    }

    function testSpoofedReceiverCallbacksRejected() public {
        vm.expectRevert(LineageWithdrawals.UnexpectedNFT.selector);
        token.onERC721Received(address(token), ALICE, 0, "");
        vm.prank(address(statements));
        vm.expectRevert(LineageWithdrawals.UnexpectedNFT.selector);
        token.onERC721Received(address(token), ALICE, 0, "");
        vm.prank(address(statements));
        vm.expectRevert(LineageWithdrawals.UnexpectedNFT.selector);
        token.onERC721Received(address(token), address(0), 0, "");
    }

    function testRawTransferDoesNotReleaseBalanceOrCreateReceipt() public {
        uint256 id = compose(0);
        vm.prank(ALICE);
        statements.transferFrom(ALICE, address(token), id);
        assertEq(statements.ownerOf(id), address(token));
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.totalReleased(), 0);
        assertEq(token.withdrawnCount(), 0);
        (address holder, uint256 issued) = token.receipts(id);
        assertEq(holder, address(0));
        assertEq(issued, 0);
        vm.expectRevert(LineageWithdrawals.AlreadyWithdrawn.selector);
        token.quote(id);
        vm.prank(ALICE);
        vm.expectRevert(LineageWithdrawals.NotStatementOwner.selector);
        token.withdraw(id, 0);
    }

    function testRecoveryOnlyFixedWalletAndNoIssuance() public {
        uint256 id = compose(0);
        uint256 reserve = token.balanceOf(address(token));
        vm.prank(ALICE);
        statements.transferFrom(ALICE, address(token), id);
        vm.prank(ALICE);
        vm.expectRevert(LineageWithdrawals.NotRecoveryWallet.selector);
        token.recoverUnissuedStatement(id);
        assertEq(statements.ownerOf(id), address(token));
        vm.prank(token.recoveryWallet());
        token.recoverUnissuedStatement(id);
        assertEq(statements.ownerOf(id), token.recoveryWallet());
        assertEq(token.balanceOf(address(token)), reserve);
        assertEq(token.totalReleased(), 0);
        assertEq(token.withdrawnCount(), 0);
        (address holder, uint256 amount) = token.receipts(id);
        assertEq(holder, address(0));
        assertEq(amount, 0);
        vm.prank(token.recoveryWallet());
        vm.expectRevert(LineageWithdrawals.StatementNotHeld.selector);
        token.recoverUnissuedStatement(id);
        address recovery = token.recoveryWallet();
        // Manual return restores the owner's ability to surrender normally.
        vm.prank(token.recoveryWallet());
        statements.transferFrom(recovery, ALICE, id);
        amount = token.quote(id);
        vm.startPrank(ALICE);
        statements.approve(address(token), id);
        token.withdraw(id, amount);
        vm.stopPrank();
        vm.prank(token.recoveryWallet());
        vm.expectRevert(LineageWithdrawals.AlreadyWithdrawn.selector);
        token.recoverUnissuedStatement(id);
    }

    function testIssuedStatementNeverRecoverableAfterBalanceLeavesHolder() public {
        (uint256 id, uint256 amount) = release(0);
        vm.prank(ALICE);
        token.transfer(BOB, amount);
        vm.prank(token.recoveryWallet());
        vm.expectRevert(LineageWithdrawals.AlreadyWithdrawn.selector);
        token.recoverUnissuedStatement(id);
        vm.prank(BOB);
        token.transfer(address(token), amount);
        vm.prank(token.recoveryWallet());
        vm.expectRevert(LineageWithdrawals.AlreadyWithdrawn.selector);
        token.recoverUnissuedStatement(id);
        assertEq(statements.ownerOf(id), address(token));
        assertEq(token.totalReleased(), amount);
        assertEq(token.withdrawnCount(), 1);
    }

    function testActualInkReleaseAndPermanentCustody() public {
        (uint256 id,uint256 amount)=release(0);
        uint256[4] memory expected=InkMath.split(amount,InkMath.count(statements.inkOf(id)));
        assertEq(abi.encode(token.inkOf(ALICE)),abi.encode(expected));
        assertEq(InkMath.sum(token.inkOf(ALICE)),token.balanceOf(ALICE));
        assertEq(statements.ownerOf(id),address(token));
        assertEq(statements.formatOf(id),token.withdrawnFormat());
        assertEq(token.renderer().displayTokenBalance(amount),token.artwork().artworkBalance(ALICE));
        assertGt(bytes(token.renderer().svg(id)).length,1000);
        assertEq(token.totalSupply(),token.maxSupply());
        assertEq(token.historyOf(ALICE).contributed,amount);
        assertEq(token.historyOf(ALICE).transfersIn,0);
        assertGt(bytes(token.artwork().tokenURI(token.artwork().tokenIdOf(ALICE))).length,0);
    }
    function testReturnedReserveInkDoesNotContaminateNewRelease() public {
        (,uint256 amount)=release(0);
        vm.prank(ALICE);token.transfer(address(token),amount);
        uint256[4] memory returned=token.inkOf(address(token));
        (uint256 id,uint256 next)=release(1);
        assertEq(abi.encode(token.inkOf(address(token))),abi.encode(returned));
        assertEq(abi.encode(token.inkOf(ALICE)),abi.encode(InkMath.split(next,InkMath.count(statements.inkOf(id)))));
        assertEq(token.historyOf(ALICE).returnsFromZero,1);
    }
    function testTwoSourcesMixThenSplit() public {
        (,uint256 first)=release(0);
        uint256[4] memory inkA=token.inkOf(ALICE);
        vm.prank(ALICE);token.transfer(BOB,first);
        (,uint256 second)=release(1);
        uint256[4] memory inkB=token.inkOf(ALICE);
        vm.prank(ALICE);token.transfer(BOB,second);
        uint256[4] memory combined=token.inkOf(BOB);
        for(uint256 c;c<4;++c)assertEq(combined[c],inkA[c]+inkB[c]);
        uint256 portion=(first+second)/3;
        uint256[4] memory expected=InkMath.split(portion,combined);
        vm.prank(BOB);token.transfer(MALLORY,portion);
        assertEq(abi.encode(token.inkOf(MALLORY)),abi.encode(expected));
        uint256[4] memory remaining=token.inkOf(BOB);
        for(uint256 c;c<4;++c)assertEq(remaining[c]+expected[c],combined[c]);
        assertEq(token.historyOf(MALLORY).statementsSurrendered,0);
        assertEq(token.historyOf(MALLORY).contributed,0);
    }
    function testTransferFromAndZeroHistory() public {
        (,uint256 amount)=release(0);
        vm.startPrank(ALICE);token.approve(BOB,amount);vm.stopPrank();
        vm.prank(BOB);token.transferFrom(ALICE,BOB,amount);
        assertEq(InkMath.sum(token.inkOf(ALICE)),0);
        assertEq(InkMath.sum(token.inkOf(BOB)),amount);
        assertEq(token.historyOf(ALICE).emptied,1);
        assertEq(token.historyOf(BOB).contributed,0);
        assertEq(token.historyOf(BOB).transfersIn,1);
        vm.prank(BOB);token.transfer(BOB,amount);
        vm.prank(BOB);token.transfer(ALICE,0);
        assertEq(token.historyOf(BOB).transfersOut,0);
        vm.prank(BOB);token.transfer(ALICE,1);
        assertEq(token.historyOf(ALICE).returnsFromZero,1);
    }
    function testArtworkStaysWhenBalanceMovesAndReturns() public {
        (uint256 id,uint256 amount)=release(0);
        uint256 aliceArt=token.artwork().tokenIdOf(ALICE);
        bytes32 beforeImage=keccak256(bytes(token.artwork().svg(aliceArt)));
        vm.prank(ALICE);token.transfer(BOB,amount);
        assertEq(token.artwork().ownerOf(aliceArt),ALICE);
        assertTrue(token.artwork().locked(aliceArt));
        assertEq(token.artwork().displayBalance(ALICE),"0");
        assertTrue(keccak256(bytes(token.artwork().svg(aliceArt)))!=beforeImage);
        assertGt(token.artwork().tokenIdOf(BOB),0);
        LineageArtwork walletArt=token.artwork();
        vm.expectRevert(LineageArtwork.WalletBound.selector);
        vm.prank(ALICE);walletArt.transferFrom(ALICE,BOB,aliceArt);
        vm.prank(BOB);token.transfer(ALICE,amount);
        assertEq(token.artwork().tokenIdOf(ALICE),aliceArt);
        assertEq(token.artwork().totalSupply(),2);
        assertEq(keccak256(bytes(token.artwork().svg(aliceArt))),beforeImage);
        assertEq(statements.ownerOf(id),address(token));
        assertEq(token.totalReleased(),amount);
    }
    /// @dev Address-level custody model only. This is NOT a Uniswap integration test.
    function testSharedCustodyMixesSourcesBeforePayout() public {
        address custodian=address(0xC057);
        (,uint256 first)=release(0);
        uint256[4] memory firstInk=token.inkOf(ALICE);
        vm.prank(ALICE);token.transfer(custodian,first);
        (,uint256 second)=release(1);
        uint256[4] memory secondInk=token.inkOf(ALICE);
        vm.prank(ALICE);token.transfer(custodian,second);
        uint256[4] memory mixed=token.inkOf(custodian);
        for(uint256 c;c<4;++c)assertEq(mixed[c],firstInk[c]+secondInk[c]);
        uint256[4] memory expected=InkMath.split(first,mixed);
        vm.prank(custodian);token.transfer(BOB,first);
        assertEq(abi.encode(token.inkOf(BOB)),abi.encode(expected));
        assertEq(token.balanceOf(custodian),second);
        assertGt(token.artwork().tokenIdOf(custodian),0);
        assertGt(token.artwork().tokenIdOf(BOB),0);
        assertEq(token.historyOf(BOB).contributed,0);
        uint256[4] memory left=token.inkOf(custodian);
        for(uint256 c;c<4;++c)assertEq(left[c]+expected[c],mixed[c]);
    }
    function testStaleQuoteRollsBackCustodyAndRelease() public {
        uint256 id=compose(0);uint256 amount=token.quote(id);
        vm.prank(ALICE);statements.approve(address(token),id);
        vm.expectRevert(abi.encodeWithSelector(LineageWithdrawals.ScoreChanged.selector,amount));
        vm.prank(ALICE);token.withdraw(id,amount+1);
        assertEq(statements.ownerOf(id),ALICE);
        assertEq(token.totalReleased(),0);
        assertEq(token.artwork().totalSupply(),0);
        assertEq(InkMath.sum(token.inkOf(ALICE)),0);
    }
    function testFuzzManyTransfersConserveAllInk(uint256 seed) public {
        (,uint256 amount)=release(0);
        uint256[4] memory original=token.inkOf(ALICE);
        for(uint256 j;j<24;++j) {
            address from=j%2==0?ALICE:BOB;address to=j%2==0?BOB:ALICE;
            uint256 n=uint256(keccak256(abi.encode(seed,j)))%(token.balanceOf(from)+1);
            vm.prank(from);token.transfer(to,n);
            uint256[4] memory a=token.inkOf(ALICE);uint256[4] memory b=token.inkOf(BOB);
            assertEq(InkMath.sum(a),token.balanceOf(ALICE));assertEq(InkMath.sum(b),token.balanceOf(BOB));
            for(uint256 c;c<4;++c)assertEq(a[c]+b[c],original[c]);
        }
        assertEq(token.balanceOf(ALICE)+token.balanceOf(BOB),amount);
    }
}
