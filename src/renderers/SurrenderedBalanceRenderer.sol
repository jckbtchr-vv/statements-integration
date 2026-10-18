// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {StatementBalanceRenderer} from "./StatementBalanceRenderer.sol";
import {IStatementRenderer} from "../IStatementRenderer.sol";
import {StatementPalette} from "./StatementPalette.sol";
interface ISurrenderReceipt { function receipts(uint256) external view returns(address holder,uint256 amount); }
interface IStatementCustody {
    function ownerOf(uint256) external view returns(address);
    function rendererOf(uint8) external view returns(address);
}
/// @notice WITHDRAWN requires both permanent custody and its issuance
/// receipt. Selecting this format or accidentally sending an NFT cannot forge it.
/// The host retains the original Statement paper rules, including eighth-page inversion.
contract SurrenderedBalanceRenderer is StatementBalanceRenderer {
    address public immutable reserve;
    constructor(address source,address reserve_) StatementBalanceRenderer(source) { reserve=reserve_; }
    function svg(uint256 id) public view override returns(string memory) {
        (address holder,uint256 amount)=ISurrenderReceipt(reserve).receipts(id);
        IStatementCustody source=IStatementCustody(address(statements));
        if(holder!=address(0)&&amount>0&&source.ownerOf(id)==reserve){
            uint256[4] memory weights=palette(id);
            return _drawLabel("WITHDRAWN",weights,StatementPalette.sum(weights)>0,Paper.Statement);
        }
        address issued=source.rendererOf(0);
        require(issued!=address(this),"Invalid fallback renderer");
        return IStatementRenderer(issued).svg(id);
    }
}
