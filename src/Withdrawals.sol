// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BalanceArtwork} from "./BalanceArtwork.sol";
import {WithdrawnRenderer} from "./renderers/WithdrawnRenderer.sol";

interface IWithdrawalStatements {
    function credits() external view returns (address);
    function ownerOf(uint256 id) external view returns (address);
    function creditScoreOf(uint256 id) external view returns (uint256);
    function rendererOf(uint8 format) external view returns (address);
    function safeTransferFrom(address from, address to, uint256 id) external;
    function setFormat(uint256 id, uint8 format) external;
}

interface IWithdrawalCredits {
    function sealedAt() external view returns (uint256);
    function supply() external view returns (uint256);
}

/// @notice An irreversible, owner-initiated exchange of a Statement for its accumulated rating.
/// One score point is one BALANCE. Both the score and ERC-20 use four decimal places.
/// No owner, upgrade, arbitrary call, mint authority, recovery, or Statement transfer-out exists.
/// The source Statements contract and its append-only renderer registry are trusted dependencies.
contract Withdrawals is ERC20, IERC721Receiver, ReentrancyGuard {
    IWithdrawalStatements public immutable statements;
    WithdrawnRenderer public immutable renderer;
    BalanceArtwork public immutable artwork;
    uint8 public immutable withdrawnFormat;
    /// @notice Exact summed rating of the sealed 122,154-Credit edition, in ten-thousandths.
    /// Minted once to this contract. See BALANCE-SUPPLY.md for the complete verification.
    uint256 public constant maxSupply = 537_523_867_072;
    /// @notice Cumulative rating released for unique Statements. Transfers back into the
    /// reserve do not reduce this counter or create another withdrawal allocation.
    uint256 public totalReleased;

    struct Receipt {
        address holder;
        uint256 amount;
    }
    mapping(uint256 statementId => Receipt) public receipts;
    uint256 public withdrawnCount;
    uint256 private _receivingId;
    address private _receivingFrom;

    error InvalidSource();
    error NotStatementOwner();
    error AlreadyWithdrawn();
    error RendererNotRegistered();
    error ScoreChanged(uint256 actual);
    error InvalidScore();
    error SupplyExceeded();
    error UnexpectedNFT();

    event Withdrawn(uint256 indexed statementId, address indexed holder, uint256 amount);

    /// @dev Creates all three contracts. Registration of renderer() as "Withdrawn" at the
    /// chosen index is a separate transaction by the current Statements owner. Until then,
    /// withdrawals fail closed. The renderer at that index can never subsequently change.
    constructor(address statements_, uint8 format_) ERC20("Balances", "BALANCE") {
        if (statements_.code.length == 0) revert InvalidSource();
        statements = IWithdrawalStatements(statements_);
        IWithdrawalCredits credits = IWithdrawalCredits(statements.credits());
        if (address(credits).code.length == 0 || credits.sealedAt() == 0) revert InvalidSource();
        if (credits.supply() == 0) revert InvalidSource();
        withdrawnFormat = format_;
        renderer = new WithdrawnRenderer(statements_);
        artwork = new BalanceArtwork(address(this));
        _mint(address(this), maxSupply);
    }

    function decimals() public pure override returns (uint8) {
        return 4;
    }

    /// @notice Allocation not yet released through withdrawals. This differs from this
    /// contract's balance if someone sends previously released tokens back; those are locked.
    function unreleasedSupply() public view returns (uint256) {
        return maxSupply - totalReleased;
    }

    function ready() public view returns (bool) {
        try statements.rendererOf(withdrawnFormat) returns (address registered) {
            return registered == address(renderer);
        } catch {
            return false;
        }
    }

    /// @notice Exact base-unit release for a live, unwithdrawn Statement. No reservation.
    function quote(uint256 id) public view returns (uint256 amount) {
        if (receipts[id].holder != address(0) || statements.ownerOf(id) == address(this)) revert AlreadyWithdrawn();
        amount = statements.creditScoreOf(id);
        if (amount == 0 || amount > maxSupply) revert InvalidScore();
    }

    /// @notice Approve this contract for this one Statement, then call as its actual owner.
    /// expectedAmount is the reviewed quote, in base units; changed scores require a new review.
    /// Transfer, white format and reserve release either all succeed or all revert. No ETH is needed
    /// beyond gas. Do not send NFTs with raw transferFrom: that bypasses every receipt mechanism.
    function withdraw(uint256 id, uint256 expectedAmount) external nonReentrant returns (uint256 amount) {
        if (!ready()) revert RendererNotRegistered();
        if (statements.ownerOf(id) != msg.sender) revert NotStatementOwner();
        amount = quote(id);
        if (amount != expectedAmount) revert ScoreChanged(amount);
        if (amount > unreleasedSupply()) revert SupplyExceeded();
        receipts[id] = Receipt(msg.sender, amount);
        ++withdrawnCount;
        totalReleased += amount;
        _receivingId = id;
        _receivingFrom = msg.sender;
        statements.safeTransferFrom(msg.sender, address(this), id);
        delete _receivingId;
        delete _receivingFrom;
        statements.setFormat(id, withdrawnFormat);
        _transfer(address(this), msg.sender, amount);
        emit Withdrawn(id, msg.sender, amount);
    }

    /// @dev Accept only the transfer currently initiated by withdraw(), never unsolicited NFTs.
    function onERC721Received(address operator, address from, uint256 id, bytes calldata)
        external
        view
        returns (bytes4)
    {
        if (
            msg.sender != address(statements) || operator != address(this) || from == address(0)
                || from != _receivingFrom || id != _receivingId
        ) revert UnexpectedNFT();
        return IERC721Receiver.onERC721Received.selector;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (value != 0 && from != to) artwork.balanceChanged(from, to);
    }
}
