# Statements / BALANCE integration source — v0.2.0-preview

A focused source package for reviewing Statement composition and permanent Statement-to-BALANCE conversion. This is a source snapshot, not a verified deployment announcement or a migration commitment.

## Status

- `src/Statements.sol`: Statement implementation source. No claim of deployed-bytecode equivalence is made by this package.
- `src/experimental/LineageWithdrawals.sol`: common BALANCE conversion implementation.
- `src/experimental/AuctionLineageWithdrawals.sol`: auction candidate with a fixed transfer-opening block and restricted early funding routes.
- `src/experimental/ConversionLineageWithdrawals.sol`: separate conversion-only candidate. Do not assume it has the auction candidate's gate behavior.
- Other contracts are dependencies or earlier implementations exercised by the included regression tests. The integration target is the selected Lineage variant, not the older `Withdrawals.sol`.
- No production BALANCE address is supplied. Confirm the final variant, constructor parameters, runtime bytecode, renderer registration and opening conditions before integration.

## Integration

The caller must own the Statement. On the Statements contract, call `approve(conversionAddress, statementId)`. On the conversion contract, read `quote(statementId)` then call `withdraw(statementId, expectedAmount)` with that exact quote. BALANCE is released to `msg.sender`, including when the owner is another smart contract. There is no recipient parameter.

`quote` returns 18-decimal BALANCE base units. Stored Statement ratings use four decimals: conversion multiplies the raw score by 10^14. Thus a rating of 53,171.2626 becomes 53,171,262,600,000,000,000,000 base units. Conversion releases pre-existing reserve tokens; it does not mint additional supply.

The quote is an amount check, not a guarantee of execution. The owner, approval, renderer, opening gates and remaining reserve must also be valid. A score change causes the reviewed amount to fail rather than silently changing it.

Conversion permanently locks the Statement and changes its displayed format. Do not transfer NFTs directly to the conversion contract. Accidentally deposited Statements that never released BALANCE can be recovered only through the fixed recovery-wallet mechanism; Statements with conversion receipts cannot use that recovery route.

For the auction candidate, non-funder conversion requires the configured retirement to be completed. Conversion can then occur before transfers open, but ordinary transfers remain locked until `transfersOpenBlock`. Before that block, only the designated funder's transfers to the configured auction/liquidity custodians are exempt. A third-party contract cannot assume early auction funding privileges. Liquidity migration and third-party treasury redemption are not implemented by this package.

See `abi/` for complete compiler-generated ABIs and `examples/convert.mjs` for the call sequence.

## Build and tests

Install Foundry, then run `forge test` from this directory. Solidity 0.8.28, optimizer 200 runs, via-IR. Required dependency source subsets are vendored, so no dependency install is needed. Foundry may download the compiler on first use.

The selected regression tests cover Statement operations, conversion, ownership, accounting and lineage. Passing them is not an independent audit or evidence of a deployed contract's configuration. See TEST-RESULTS.txt for the actual package run.

## Provenance and license

Project Solidity files retain their MIT SPDX notices. Dependency files retain upstream notices and licenses. OpenZeppelin source revision: cab19933c33c2ad1d4c7a84864a3601dddfd16f3. forge-std source revision: bf647bd6046f2f7da30d0c2bf435e5c76a780c1b. SOURCE-MANIFEST.json records SHA-256 hashes of the copied source files. This package includes no private repository history, secrets or production deployment configuration.

MIT for project code; see LICENSE and the vendored dependency licenses. No endorsement of third-party tokens, pools or migration arrangements is implied.

## Preview compatibility policy

This is v0.2.0-preview, not a production integration commitment. The quote → approve → withdraw interface has been rehearsed, but interface, launch gates and configuration remain provisional until a verified release. Integrators should keep addresses and timing configurable and must not assume early transfer privileges, additional auction deposits or coordinated liquidity migration.

A production release will identify the final chain, addresses, constructor settings and verified runtime code. Integrators must check that release before accepting deposits dependent on the integration. Incompatible changes will receive a new version with migration notes; preview versions may break compatibility. Existing published tags will not be silently replaced. Frontend or artwork changes do not necessarily change the conversion ABI.

Publishing this source does not upgrade any deployed Statement contract. Deployed-source equivalence must be established separately. This package is not an independent security audit.

## Artwork changes in v0.2.0-preview

- Artwork IDs now start at 1 and increment in first-receipt execution order. They are no longer derived from wallet addresses. Always query `tokenIdOf(wallet)`; do not compute the ID from the address. IDs persist at zero balance and on later receipt.
- Metadata names are permanent `Balance #<tokenId>` identifiers, rather than the current balance.
- The current eighteen-decimal artwork renders exact zero as `0`, positive amounts below 0.01 as `<0.01`, and other amounts truncated to two decimals. Exact amounts remain in the Balance metadata trait. Type/pixel size stays fixed relative to the canvas.
- Includes metadata, sequential-ID, dust-boundary and full-scale rendering regression tests.

These are source changes for new deployments. They do not upgrade existing contracts. The auction conversion/transfer gates and quote/approve/withdraw interface are unchanged from v0.1.0-preview. Artwork bytecode, token-ID semantics and deployment hashes have changed; regenerate deployment predictions and verify final deployed addresses. Full raw metadata traits remain available; the simplified audit page presentation is not a removal of those traits.
