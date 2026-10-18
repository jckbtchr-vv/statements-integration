// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {StatementBalanceRenderer} from "../src/renderers/StatementBalanceRenderer.sol";
contract BalanceSourceMock {
    uint256 public overprints;
    function creditScoreOf(uint256) external pure returns(uint256){return 1508155218;}
    function inkOf(uint256) external pure returns(uint256[240] memory words){words[0]=0x1111;words[1]=0x2222;}
    function overprintsOf(uint256) external view returns(uint256){return overprints;}
    function setOverprints(uint256 n) external {overprints=n;}
}
contract StatementBalanceRendererTest is Test {
    StatementBalanceRenderer renderer;
    BalanceSourceMock source;
    function setUp() public {source=new BalanceSourceMock();renderer=new StatementBalanceRenderer(address(source));}
    function testScoreFormatting() public view {
        assertEq(renderer.displayScore(1508155218),"150,815.52");
        assertEq(renderer.displayScore(19999),"1.99");
        assertEq(renderer.displayScore(0),"0.00");
        assertEq(renderer.displayScore(537523867072),"53,752,386.70");
    }
    function testPaletteAndReadOnlySource() public view {
        uint256[4] memory p=renderer.palette(1);assertEq(p[0],4);assertEq(p[1],4);assertEq(p[2],0);assertEq(p[3],0);
        string memory image=renderer.svg(1);
        assertTrue(bytes(image).length>1000);assertEq(renderer.html(1),"");
        assertTrue(contains(image,"BALANCE: 150,815.52"));assertTrue(contains(image,"v135h-3983z")); // equal C/M widths; underline is one Receipt pixel high
        assertTrue(contains(image,"9135h")); // 87 pixel rows: raised underline
        assertTrue(contains(image,'stroke-width="13"'));
    }
    function testBlackPaperCompensation() public {
        string memory before=renderer.svg(1);source.setOverprints(7);string memory after_=renderer.svg(1);
        assertTrue(contains(before,'height="20000" fill="#ffffff"'));
        assertTrue(contains(after_,'height="20000" fill="#000000"'));
        assertTrue(contains(after_,"#00b5e2"));
    }
    function testPreviewSVG() public { emit log_string(renderer.svg(1)); }
    function testZeroAndMaximum() public view {
        uint256[4] memory weights=[uint256(1),2,3,4];
        assertFalse(contains(renderer.draw(0,weights),"9135h"));
        assertTrue(contains(renderer.draw(537523867072,weights),"53,752,386.70"));
    }
    function contains(string memory a,string memory b) private pure returns(bool){bytes memory x=bytes(a);bytes memory y=bytes(b);for(uint256 i;i+y.length<=x.length;i++){bool ok=true;for(uint256 j;j<y.length;j++)if(x[i+j]!=y[j]){ok=false;break;}if(ok)return true;}return false;}
}
