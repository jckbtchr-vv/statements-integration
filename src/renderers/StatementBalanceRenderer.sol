// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IStatementRenderer} from "../IStatementRenderer.sol";
import {BalancePixels} from "./BalancePixels.sol";
import {Draw} from "./Draw.sol";
import {StatementPalette} from "./StatementPalette.sol";
import {PixelOrder} from "./PixelOrder.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

interface IBalanceStatementSource {
    function creditScoreOf(uint256 id) external view returns (uint256);
    function inkOf(uint256 id) external view returns (uint256[240] memory);
    function overprintsOf(uint256 id) external view returns (uint256);
}

/// @notice BALANCE: the Statement's fixed rating and original stored CMYK composition.
/// Pixels measure occupied plate bits, not historical quantities of overlapping ink.
contract StatementBalanceRenderer is IStatementRenderer {
    // Statements postprocess every format at the eighth constituent page.
    // Numeric balances compensate to stay white; withdrawn Statements inherit it.
    enum Paper { White, Compensated, Statement }
    IBalanceStatementSource public immutable statements;
    constructor(address source) { statements = IBalanceStatementSource(source); }

    function html(uint256) external pure returns (string memory) { return ""; }
    function palette(uint256 id) public view returns (uint256[4] memory) {
        return StatementPalette.count(statements.inkOf(id));
    }
    function svg(uint256 id) public view virtual returns (string memory) {
        return _draw(statements.creditScoreOf(id), palette(id), statements.overprintsOf(id) >= 7);
    }
    /// @notice Standalone white-paper preview, before Statements' black-paper postprocessing.
    function draw(uint256 score, uint256[4] memory weights) external pure returns (string memory) {
        return _draw(score, weights, false);
    }
    /// @notice Same artwork for an eighteen-decimal wallet balance, including sub-rating dust.
    function drawTokenBalance(uint256 amount, uint256[4] memory weights) external pure returns (string memory) {
        return _drawScaled(amount, 1e18, weights, false);
    }
    function displayTokenBalance(uint256 amount) external pure returns (string memory) {
        return _display(amount, 1e18);
    }
    /// @notice Two decimals truncated from the four-decimal rating.
    function displayScore(uint256 score) public pure returns (string memory) {
        return _display(score, 10000);
    }
    function _display(uint256 amount, uint256 unit) private pure returns (string memory) {
        if (unit == 1e18) {
            if (amount == 0) return "0";
            if (amount < 1e16) return "<0.01";
        }
        bytes memory digits = bytes(Strings.toString(amount / unit));
        bytes memory whole = new bytes(digits.length + (digits.length - 1) / 3);
        uint256 at = whole.length;
        for(uint256 i=digits.length;i>0;) {
            whole[--at]=digits[--i];
            if(i>0 && (digits.length-i)%3==0) whole[--at]=",";
        }
        uint256 cents=amount%unit/(unit/100);
        return string.concat(string(whole),".",cents<10?"0":"",Strings.toString(cents));
    }
    function _color(uint256 c, Paper paper) private pure returns(bytes memory) {
        if(c==0) return "#00b5e2";
        if(c==1) return "#e4007c";
        if(c==2) return "#ffd100";
        // Compensate for the host's inversion so BALANCE always has white paper.
        if(paper==Paper.Statement)return "#111111";
        return paper==Paper.Compensated?bytes("#ffffff"):bytes("#000000");
    }
    function _draw(uint256 score, uint256[4] memory weights, bool inverted) private pure returns(string memory) {
        return _drawScaled(score, 10000, weights, inverted);
    }
    function _drawScaled(uint256 amount, uint256 unit, uint256[4] memory weights, bool inverted) private pure returns(string memory) {
        return _drawLabel(bytes(_display(amount,unit)),weights,amount>0 && StatementPalette.sum(weights)>0,
            inverted?Paper.Compensated:Paper.White);
    }
    function _drawLabel(bytes memory label, uint256[4] memory weights, bool hasInk, Paper paper) internal pure returns(string memory) {
        require(label.length>0 && label.length<=16,"Balance grid width");
        uint80[] memory masks=new uint80[](label.length);
        uint256 count;
        for(uint256 i;i<label.length;i++) {
            masks[i]=BalancePixels._glyph(label[i]);
            for(uint256 bit;bit<BalancePixels.WIDTH*BalancePixels.ROWS;bit++) if(masks[i] & (uint80(1)<<bit)!=0) count++;
        }
        uint256[4] memory allocation;
        if(hasInk) allocation=StatementPalette.split(count,weights);
        else allocation[3]=count;
        // Shuffle exact color ranks so regular stepping cannot create bands.
        uint256[] memory order=_pixelInks(count,label,allocation);
        uint256 lineWidth=(label.length*BalancePixels.ADVANCE-1)*BalancePixels.PITCH;
        uint256 start=(BalancePixels.FIELD_WIDTH-lineWidth)/2;
        Draw.Out memory out=Draw.init(40000);
        // Explicit portrait dimensions avoid a rasterizer's default SVG viewport.
        // Preserve the page, cap height, underline position and Statement padding.
        Draw.str(out,'<svg xmlns="http://www.w3.org/2000/svg" width="3000" height="3750" viewBox="0 0 16000 20000"><title>');
        if(paper!=Paper.Statement)Draw.str(out,'BALANCE: ');
        if (label[0] == "<") Draw.str(out,"&lt;0.01");
        else Draw.str(out,label);
        Draw.str(out,'</title><rect width="16000" height="20000" fill="');
        Draw.str(out,paper==Paper.Compensated?bytes("#000000"):bytes("#ffffff"));
        Draw.str(out,'"/><g shape-rendering="crispEdges" transform="translate(1280 1600)">');
        _drawPixels(out,masks,order,start,paper);
        if(hasInk) {
            uint256[4] memory widths=StatementPalette.split(lineWidth,weights);
            uint256 x=start;
            for(uint256 c;c<4;c++) {
                if(widths[c]>0) {
                    Draw.str(out,'<path fill="');Draw.str(out,_color(c,paper));Draw.str(out,'" d="');
                    Draw.run(out,x,87*105,"h",widths[c]);Draw.str(out,"v135h-");Draw.u(out,widths[c]);Draw.str(out,'z"/>');
                }
                x+=widths[c];
            }
        }
        Draw.str(out,"</g></svg>");return Draw.done(out);
    }
    function _drawPixels(Draw.Out memory out,uint80[] memory masks,uint256[] memory order,uint256 start,Paper paper) private pure {
        for(uint256 ink;ink<4;ink++) {
            Draw.str(out,'<path fill="');Draw.str(out,_color(ink,paper));
            Draw.str(out,'" stroke="');Draw.str(out,_color(ink,paper));
            Draw.str(out,'" stroke-width="13" d="');
            uint256 cell;
            for(uint256 row;row<BalancePixels.ROWS;row++) for(uint256 i;i<masks.length;i++) for(uint256 col;col<BalancePixels.WIDTH;col++) {
                if(masks[i] & (uint80(1)<<(row*BalancePixels.WIDTH+col))==0) continue;
                if(order[cell++]!=ink) continue;
                Draw.run(out,start+(i*BalancePixels.ADVANCE+col)*BalancePixels.PITCH,BalancePixels.TOP+row*BalancePixels.PITCH,"h",BalancePixels.PITCH);
                Draw.str(out,"v135h-135z");
            }
            Draw.str(out,'"/>');
        }
    }
    function _pixelInks(uint256 count,bytes memory label,uint256[4] memory allocation) private pure returns(uint256[] memory order) {
        order=PixelOrder.ranks(count,label);
        uint256 cm=allocation[0]+allocation[1];
        uint256 cmy=cm+allocation[2];
        for(uint256 i;i<count;i++) {
            uint256 rank=order[i];
            order[i]=rank<allocation[0]?0:rank<cm?1:rank<cmy?2:3;
        }
    }
}
