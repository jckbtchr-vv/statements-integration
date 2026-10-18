// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {BalancePixels} from "./renderers/BalancePixels.sol";

/// @notice One automatically issued, permanently wallet-bound balance artwork per recipient.
/// ERC-5192 identifies the lock; ERC-4906 announces balance/metadata changes to indexers.
/// First receipt creates it, including for smart wallets/contracts. The token reserve is excluded.
/// Neither moving units nor reaching zero destroys the NFT. No recipient callbacks are made.
contract BalanceArtwork is ERC721 {
    IERC20 public immutable token;
    /// @notice Artwork addresses in first-receipt order; bounded pagination powers the public gallery.
    address[] public wallets;
    mapping(address => uint256) private artworkIds;
    error WalletBound();
    error OnlyToken();
    error PageTooLarge();

    event Locked(uint256 tokenId);
    event MetadataUpdate(uint256 _tokenId);

    constructor(address token_) ERC721("Balances", "BALANCE") {
        token = IERC20(token_);
    }

    function tokenIdOf(address wallet) public view returns (uint256) {
        return artworkIds[wallet];
    }

    function _issue(address wallet) private returns (uint256 id) {
        if (wallet == address(0) || wallet == address(token)) return 0;
        id = artworkIds[wallet];
        if (id != 0) return id;
        if (token.balanceOf(wallet) == 0) return 0;
        wallets.push(wallet);
        id = wallets.length;
        artworkIds[wallet] = id;
        // This artwork can never transfer or burn, so receiver compatibility is irrelevant.
        // _mint deliberately makes no ERC-721 receiver call: swaps and ERC-20 transfers must
        // not acquire a callback or fail because a pool/smart wallet cannot receive NFTs.
        _mint(wallet, id);
        emit Locked(id);
    }

    function totalSupply() external view returns (uint256) {
        return wallets.length;
    }

    /// @notice Current balances for up to 64 artworks, including addresses at zero.
    function balances(uint256 from, uint256 limit)
        external
        view
        returns (address[] memory owners, uint256[] memory amounts)
    {
        if (limit > 64) revert PageTooLarge();
        uint256 count = from >= wallets.length ? 0 : wallets.length - from;
        if (count > limit) count = limit;
        owners = new address[](count);
        amounts = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            address wallet = wallets[from + i];
            owners[i] = wallet;
            amounts[i] = token.balanceOf(wallet);
        }
    }

    function locked(uint256 id) external view returns (bool) {
        _requireOwned(id);
        return true;
    }

    function approve(address, uint256) public pure override {
        revert WalletBound();
    }

    function setApprovalForAll(address, bool) public pure override {
        revert WalletBound();
    }

    function _update(address to, uint256 id, address auth) internal override returns (address) {
        if (_ownerOf(id) != address(0) || to == address(0)) revert WalletBound();
        return super._update(to, id, auth);
    }

    /// @dev Called only by the immutable ERC-20 after balances change; no recipient callbacks.
    function balanceChanged(address from, address to) external {
        if (msg.sender != address(token)) revert OnlyToken();
        uint256 id = tokenIdOf(from);
        if (id != 0) emit MetadataUpdate(id);
        if (to != from) {
            id = _issue(to);
            if (id != 0) emit MetadataUpdate(id);
        }
    }

    /// @notice Exact balance with grouping and up to four fractional digits, including zero.
    function displayBalance(address wallet) public view returns (string memory) {
        return _formatBalance(token.balanceOf(wallet));
    }

    /// @notice Artwork shows at most two fractional digits, truncated without changing token units.
    function artworkBalance(address wallet) public view returns (string memory) {
        return _formatBalance(token.balanceOf(wallet) / 100 * 100);
    }

    function _formatBalance(uint256 amount) private pure returns (string memory) {
        bytes memory digits = bytes(Strings.toString(amount / 10_000));
        bytes memory whole = new bytes(digits.length + (digits.length - 1) / 3);
        uint256 at = whole.length;
        for (uint256 i = digits.length; i > 0;) {
            whole[--at] = digits[--i];
            if (i > 0 && (digits.length - i) % 3 == 0) whole[--at] = ",";
        }
        uint256 rem = amount % 10_000;
        if (rem == 0) return string(whole);
        bytes memory fraction = new bytes(4);
        for (uint256 i = 4; i > 0;) {
            fraction[--i] = bytes1(uint8(48 + rem % 10));
            rem /= 10;
        }
        uint256 end = 4;
        while (fraction[end - 1] == "0") --end;
        bytes memory trimmed = new bytes(end);
        for (uint256 i; i < end; ++i) {
            trimmed[i] = fraction[i];
        }
        return string.concat(string(whole), ".", string(trimmed));
    }

    function svg(uint256 id) public view returns (string memory) {
        return BalancePixels.draw(artworkBalance(_requireOwned(id)));
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        address wallet = _requireOwned(id);
        string memory json = string.concat(
            '{"name":"Balance #',
            Strings.toString(id),
            '","description":"The balance is the artwork. This artwork is created automatically on first receipt and stays with its wallet. Its number is the current balance, including zero, truncated to two decimal places.",',
            '"image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svg(id))),
            '","attributes":[{"trait_type":"Wallet","value":"',
            Strings.toHexString(wallet),
            '"},{"trait_type":"Balance","value":"',
            displayBalance(wallet),
            '"}]}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function supportsInterface(bytes4 id) public view override returns (bool) {
        return id == 0xb45a3c0e || id == 0x49064906 || super.supportsInterface(id);
    }
}
