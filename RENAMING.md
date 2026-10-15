# BSC -> Windpay renaming

The upstream system contracts come from bnb-chain/bsc-genesis-contract. The
contracts Windpay actually runs have been renamed; the BNB cross-chain contracts
have deliberately not been.

## Renamed

    BSCValidatorSet.sol          -> WindpayValidatorSet.sol
    BSCGovernor.sol              -> WindpayGovernor.sol
    BSCTimelock.sol              -> WindpayTimelock.sol
    extension/BSCValidatorSetTool.sol -> extension/WindpayValidatorSetTool.sol
    interface/0.6.x/IBSCValidatorSet.sol   -> IWindpayValidatorSet.sol
    interface/0.6.x/IBSCValidatorSetV2.sol -> IWindpayValidatorSetV2.sol
    interface/0.8.x/IBSCValidatorSet.sol   -> IWindpayValidatorSet.sol
    test/utils/interface/IBSC*.sol  (4 files)
    abi/bsc{validatorset,governor,timelock}.abi

Identifiers: bscValidatorSet -> windpayValidatorSet (138), bscChainID ->
windpayChainID (27), bscFeeAddr -> windpayFeeAddr, plus the contract and
interface names above. GovToken NAME string -> Windpay Governance Token.

## Deleted (upstream BSC-only tooling, meaningless here)

    scripts/check-bsc-hardfork-bytecode.ts        compares against bnb-chain/bsc
    scripts/check-bsc-hardfork-bytecode.security.test.js
    .github/workflows/check-bsc-hardfork-bytecode.yml
    scripts/bep171-unlock-bot.ts                  points at bsc-dataseed RPC

## Deliberately NOT renamed

IParamSubscriber - Su-bscr-iber contains the letters bsc. Not a BSC reference.

TokenHub.sol, TokenRecoverPortal.sol, deprecated/Staking.sol,
deprecated/TokenManager.sol, test/utils/interface/IStaking.sol, wbnb/WBNB.sol -
their BSC and BNB mentions describe real BNB Beacon Chain <-> BSC transfers.
These contracts are deployed on Windpay but have never been called. Renaming
their comments would make them say something untrue.

scripts/generate.py keeps two BSC mainnet/BSC testnet help strings: those
commands generate genesis for BNB's own networks. Windpay's genesis was built
by ../../chain-setup-scripts/, not by this file.

## Verification

Renaming changes the compiled bytecode, so this tree can no longer be used to
verify the contracts deployed on chain 5552040. The original tree plus its out/
artifacts is frozen at ../windpay-contracts-verification-archive/.

Checked after renaming: all 133 local imports resolve, every Windpay type that is
referenced is declared, no BSC identifier remains outside the list above.
