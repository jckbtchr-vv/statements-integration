// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {LineageArtwork} from "./LineageArtwork.sol";
import {InkMath} from "./InkMath.sol";
import {SurrenderedBalanceRenderer} from "../renderers/SurrenderedBalanceRenderer.sol";

interface IWithdrawalStatements {
    function inkOf(uint256 id) external view returns (uint256[240] memory);
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

/// @dev EXPERIMENTAL. AuctionLineageWithdrawals adds the tested CCA launch gate.
/// Color accounting is per custody address, not per Uniswap v4 pool.
/// @notice An irreversible, owner-initiated exchange of a Statement for its accumulated rating.
/// One score point is one BALANCE. Four-decimal ratings convert exactly to 18-decimal tokens.
/// No owner, upgrade, arbitrary call or mint authority exists. Issued Statements cannot leave.
/// Only unissued accidental Statement deposits can be recovered to the fixed recovery wallet.
/// The source Statements contract and its append-only renderer registry are trusted dependencies.
contract LineageWithdrawals is ERC20, IERC721Receiver, ReentrancyGuard {
    using SafeCast for uint256;
    IWithdrawalStatements public immutable statements;
    SurrenderedBalanceRenderer public immutable renderer;
    LineageArtwork public immutable artwork;
    uint8 public immutable withdrawnFormat;
    uint256 public constant SCORE_TO_TOKEN = 1e14;
    /// @notice Exact edition rating, rescaled from four to eighteen decimals.
    /// Initial reserve is 53,752,386.7072 Balance, minted once to this contract.
    /// The auction specialization retires a fixed amount from its funder after release.
    uint256 public constant maxSupply = 537_523_867_072 * SCORE_TO_TOKEN;
    /// @notice Cumulative rating released for unique Statements. Transfers back into the
    /// reserve do not reduce this counter or create another withdrawal allocation.
    uint256 public totalReleased;

    struct Receipt {
        address holder;
        uint256 amount;
    }
    mapping(uint256 statementId => Receipt) public receipts;
    /// @notice Fixed visualizevalue.eth address; ENS changes cannot redirect recovery.
    address public constant recoveryWallet = 0xc8f8e2F59Dd95fF67c3d39109ecA2e2A017D4c8a;
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
    error NotRecoveryWallet();
    error StatementNotHeld();

    event UnissuedStatementRecovered(uint256 indexed statementId, address indexed recipient);

    event Withdrawn(uint256 indexed statementId, address indexed holder, uint256 amount);

    /// @dev Creates all three contracts. Registration of renderer() as "Balance" at the
    /// chosen index is a separate transaction by the current Statements owner. Until then,
    /// withdrawals fail closed. The renderer at that index can never subsequently change.
    constructor(address statements_, uint8 format_) ERC20("Balances", "BALANCE") {
        if (statements_.code.length == 0) revert InvalidSource();
        statements = IWithdrawalStatements(statements_);
        IWithdrawalCredits credits = IWithdrawalCredits(statements.credits());
        if (address(credits).code.length == 0 || credits.sealedAt() == 0) revert InvalidSource();
        if (credits.supply() == 0) revert InvalidSource();
        withdrawnFormat = format_;
        renderer = new SurrenderedBalanceRenderer(statements_, address(this));
        artwork = new LineageArtwork(address(this));
        _mint(address(this), maxSupply);
    }

    function decimals() public pure override returns (uint8) {
        return 18;
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
        uint256 score = statements.creditScoreOf(id);
        if (score == 0 || score > maxSupply / SCORE_TO_TOKEN) revert InvalidScore();
        amount = score * SCORE_TO_TOKEN;
    }

    /// @notice Approve this contract for this one Statement, then call as its actual owner.
    /// expectedAmount is the reviewed quote, in base units; changed scores require a new review.
    /// Transfer, Balance format and reserve release either all succeed or all revert. No ETH is needed
    /// beyond gas. Do not send NFTs with raw transferFrom: that bypasses every receipt mechanism.
    function withdraw(uint256 id, uint256 expectedAmount) external nonReentrant returns (uint256 amount) {
        if (!ready()) revert RendererNotRegistered();
        _checkWithdrawal();
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
        _releaseInk = InkMath.split(amount, InkMath.count(statements.inkOf(id)));
        _releasing = true;
        StoredHistory storage contributor = _history[msg.sender];
        contributor.contributed = (uint256(contributor.contributed) + amount).toUint128();
        ++contributor.statementsSurrendered;
        _transfer(address(this), msg.sender, amount);
        emit Withdrawn(id, msg.sender, amount);
    }

    /// @notice Recover only accidental deposits that never released Balance.
    /// The fixed recipient must verify the original transfer offchain and return the NFT.
    /// No caller-selected recipient, approvals, or recovery of issued Statements is possible.
    function recoverUnissuedStatement(uint256 id) external nonReentrant {
        if (msg.sender != recoveryWallet) revert NotRecoveryWallet();
        Receipt memory receipt = receipts[id];
        if (receipt.holder != address(0) || receipt.amount != 0) revert AlreadyWithdrawn();
        if (statements.ownerOf(id) != address(this)) revert StatementNotHeld();
        statements.safeTransferFrom(address(this), recoveryWallet, id);
        emit UnissuedStatementRecovered(id, recoveryWallet);
    }

    /// @dev A launch specialization may require its supply to be finalized first.
    function _checkWithdrawal() internal view virtual {}

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

    // Reserve issuance is uncolored until surrender. Returned tokens retain their own ink.
    // Each colour is bounded by the fixed reserve (less than 2^86 base units).
    // Two uint128 channels share one slot; public quantities remain uint256.
    struct Ink { uint128 cyan; uint128 magenta; uint128 yellow; uint128 black; }
    mapping(address => Ink) private _ink;
    struct History {
        uint256 firstReceipt;
        uint256 received;
        uint256 sent;
        uint256 transfersIn;
        uint256 transfersOut;
        uint256 contributed;
        uint256 statementsSurrendered;
        uint256 peak;
        uint256 emptied;
        uint256 returnsFromZero;
    }
    // Keep cumulative turnover at uint256: the same tokens can circulate repeatedly.
    // Received is exactly sent + current balance, so it needs no separate storage.
    // For the reserve, received means returned units, excluding its initial mint.
    // Contribution and peak cannot exceed supply. Counts/timestamps use checked
    // uint64 arithmetic (over 18 quintillion events); zero-return counts use uint128.
    struct StoredHistory {
        uint256 sent;
        uint128 contributed;
        uint128 peak;
        uint64 firstReceipt;
        uint64 transfersIn;
        uint64 transfersOut;
        uint64 statementsSurrendered;
        uint128 emptied;
        uint128 returnsFromZero;
    }
    mapping(address => StoredHistory) private _history;
    uint256[4] private _releaseInk;
    bool private _releasing;
    event InkMoved(address indexed from, address indexed to, uint256[4] ink);
    function inkOf(address wallet) public view returns (uint256[4] memory) {
        Ink storage ink = _ink[wallet];
        return [uint256(ink.cyan), uint256(ink.magenta), uint256(ink.yellow), uint256(ink.black)];
    }
    function _storeInk(address wallet, uint256[4] memory ink) private {
        _ink[wallet] = Ink(ink[0].toUint128(), ink[1].toUint128(), ink[2].toUint128(), ink[3].toUint128());
    }
    function historyOf(address wallet) public view returns (History memory) {
        StoredHistory storage h = _history[wallet];
        return History(h.firstReceipt, _received(wallet, balanceOf(wallet)), h.sent, h.transfersIn, h.transfersOut,
            h.contributed, h.statementsSurrendered, h.peak, h.emptied, h.returnsFromZero);
    }
    function _received(address wallet, uint256 currentBalance) private view returns (uint256) {
        if (wallet == address(this)) return currentBalance - unreleasedSupply();
        return _history[wallet].sent + currentBalance;
    }
    // Preserve the original public mapping getter's signature, order and output widths.
    function history(address wallet) external view returns (
        uint256 firstReceipt, uint256 received, uint256 sent, uint256 transfersIn,
        uint256 transfersOut, uint256 contributed, uint256 statementsSurrendered,
        uint256 peak, uint256 emptied, uint256 returnsFromZero
    ) {
        History memory h = historyOf(wallet);
        return (h.firstReceipt, h.received, h.sent, h.transfersIn, h.transfersOut,
            h.contributed, h.statementsSurrendered, h.peak, h.emptied, h.returnsFromZero);
    }
    function _update(address from, address to, uint256 value) internal virtual override {
        uint256 beforeTo = balanceOf(to);
        super._update(from, to, value);
        if (value == 0 || from == to || from == address(0)) return;
        uint256[4] memory moving;
        bool release = from == address(this) && _releasing;
        if (release) {
            moving = _releaseInk;
            delete _releaseInk;
            _releasing = false;
        } else {
            uint256[4] memory remaining = inkOf(from);
            moving = InkMath.split(value, remaining);
            for (uint256 c; c < 4; ++c) remaining[c] -= moving[c];
            _storeInk(from, remaining);
            StoredHistory storage sender = _history[from];
            sender.sent += value;
            ++sender.transfersOut;
            if (balanceOf(from) == 0) ++sender.emptied;
        }
        // The auction specialization has one fixed creator retirement. Burned ink
        // leaves circulation; it must not create a zero-address balance/history.
        if (to == address(0)) {
            emit InkMoved(from, to, moving);
            artwork.balanceChanged(from, to);
            return;
        }
        uint256[4] memory arriving = inkOf(to);
        for (uint256 c; c < 4; ++c) arriving[c] += moving[c];
        _storeInk(to, arriving);
        StoredHistory storage recipient = _history[to];
        // Evaluated after the transfer: equal to this receipt only on first receipt.
        // Checked addition also preserves the former uint256 turnover overflow guard.
        if (_received(to, balanceOf(to)) == value) recipient.firstReceipt = block.timestamp.toUint64();
        else if (beforeTo == 0) ++recipient.returnsFromZero;
        if (!release) ++recipient.transfersIn;
        if (balanceOf(to) > recipient.peak) recipient.peak = balanceOf(to).toUint128();
        emit InkMoved(from, to, moving);
        artwork.balanceChanged(from, to);
    }
}
