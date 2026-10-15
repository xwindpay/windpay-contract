pragma solidity ^0.8.10;

import "./utils/Deployer.sol";

contract ValidatorSetTest is Deployer {
    using RLPEncode for *;

    event validatorSetUpdated();
    event systemTransfer(uint256 amount);
    event RewardDistributed(address indexed operatorAddress, uint256 reward);
    event deprecatedDeposit(address indexed validator, uint256 amount);
    event validatorDeposit(address indexed validator, uint256 amount);
    event failReasonWithStr(string message);
    event finalityRewardDeposit(address indexed validator, uint256 amount);
    event deprecatedFinalityRewardDeposit(address indexed validator, uint256 amount);
    event unsupportedPackage(uint64 indexed packageSequence, uint8 indexed channelId, bytes payload);

    uint256 public totalInComing;
    uint256 public burnRatio;
    uint256 public burnRatioScale;
    uint256 public maxNumOfWorkingCandidates;
    uint256 public numOfCabinets;
    uint256 public systemRewardBaseRatio;
    uint256 public systemRewardRatioScale;

    address public coinbase;
    address public validator0;
    mapping(address => bool) public cabinets;

    function setUp() public {
        // add operator
        bytes memory key = "addOperator";
        bytes memory valueBytes = abi.encodePacked(address(windpayValidatorSet));
        vm.expectEmit(false, false, false, true, address(systemReward));
        emit paramChange(string(key), valueBytes);
        _updateParamByGovHub(key, valueBytes, address(systemReward));
        assertTrue(systemReward.isOperator(address(windpayValidatorSet)));

        burnRatio =
            windpayValidatorSet.isSystemRewardIncluded() ? windpayValidatorSet.burnRatio() : windpayValidatorSet.INIT_BURN_RATIO();
        burnRatioScale = windpayValidatorSet.BLOCK_FEES_RATIO_SCALE();
        systemRewardBaseRatio = windpayValidatorSet.isSystemRewardIncluded()
            ? windpayValidatorSet.systemRewardBaseRatio()
            : windpayValidatorSet.INIT_SYSTEM_REWARD_RATIO();
        systemRewardRatioScale = windpayValidatorSet.BLOCK_FEES_RATIO_SCALE();
        totalInComing = windpayValidatorSet.totalInComing();
        maxNumOfWorkingCandidates = windpayValidatorSet.maxNumOfWorkingCandidates();
        numOfCabinets = windpayValidatorSet.numOfCabinets();

        address[] memory validators = windpayValidatorSet.getValidators();
        validator0 = validators[0];

        coinbase = block.coinbase;
        vm.deal(coinbase, 100 ether);

        // set gas price to zero to send system slash tx
        vm.txGasPrice(0);
        vm.mockCall(address(0x66), bytes(""), hex"01");
    }

    function testDeposit(uint256 amount) public {
        vm.assume(amount >= 1e16);
        vm.assume(amount <= 1e19);

        vm.expectRevert("the message sender must be the block producer");
        windpayValidatorSet.deposit{ value: amount }(validator0);

        vm.startPrank(coinbase);
        vm.expectRevert("deposit value is zero");
        windpayValidatorSet.deposit(validator0);

        uint256 realAmount0 = _calcIncoming(amount);
        vm.expectEmit(true, false, false, true, address(windpayValidatorSet));
        emit validatorDeposit(validator0, realAmount0);
        windpayValidatorSet.deposit{ value: amount }(validator0);

        vm.stopPrank();
        assertEq(windpayValidatorSet.getTurnLength(), 8);
        bytes memory key = "turnLength";
        bytes memory value = bytes(hex"0000000000000000000000000000000000000000000000000000000000000005"); // 5
        _updateParamByGovHub(key, value, address(windpayValidatorSet));
        assertEq(windpayValidatorSet.getTurnLength(), 5);

        key = "systemRewardAntiMEVRatio";
        value = bytes(hex"0000000000000000000000000000000000000000000000000000000000000200"); // 512
        _updateParamByGovHub(key, value, address(windpayValidatorSet));
        assertEq(windpayValidatorSet.systemRewardAntiMEVRatio(), 512);
        vm.startPrank(coinbase);

        uint256 realAmount1 = _calcIncoming(amount);
        vm.expectEmit(true, false, false, true, address(windpayValidatorSet));
        emit validatorDeposit(validator0, realAmount1);
        windpayValidatorSet.deposit{ value: amount }(validator0);

        address newAccount = _getNextUserAddress();
        vm.expectEmit(true, false, false, true, address(windpayValidatorSet));
        emit deprecatedDeposit(newAccount, realAmount1);
        windpayValidatorSet.deposit{ value: amount }(newAccount);

        assertEq(windpayValidatorSet.totalInComing(), totalInComing + realAmount0 + realAmount1);
        vm.stopPrank();
    }

    function testGov() public {
        bytes memory key = "maxNumOfWorkingCandidates";
        bytes memory value = bytes(hex"0000000000000000000000000000000000000000000000000000000000000015"); // 21
        vm.expectEmit(false, false, false, true, address(govHub));
        emit failReasonWithStr("the maxNumOfWorkingCandidates must be not greater than maxNumOfCandidates");
        _updateParamByGovHub(key, value, address(windpayValidatorSet));
        assertEq(windpayValidatorSet.maxNumOfWorkingCandidates(), maxNumOfWorkingCandidates);

        value = bytes(hex"000000000000000000000000000000000000000000000000000000000000000a"); // 10
        _updateParamByGovHub(key, value, address(windpayValidatorSet));
        assertEq(windpayValidatorSet.maxNumOfWorkingCandidates(), 10);

        key = "maxNumOfCandidates";
        value = bytes(hex"0000000000000000000000000000000000000000000000000000000000000005"); // 5
        _updateParamByGovHub(key, value, address(windpayValidatorSet));
        assertEq(windpayValidatorSet.maxNumOfCandidates(), 5);
        assertEq(windpayValidatorSet.maxNumOfWorkingCandidates(), 5);

        key = "systemRewardBaseRatio";
        value = bytes(hex"0000000000000000000000000000000000000000000000000000000000000400"); // 1024
        _updateParamByGovHub(key, value, address(windpayValidatorSet));
        assertEq(windpayValidatorSet.systemRewardBaseRatio(), 1024);
    }

    function testValidateSetChange() public {
        for (uint256 i; i < 5; ++i) {
            (, address[] memory consensusAddrs, uint64[] memory votingPowers, bytes[] memory voteAddrs) =
                _batchCreateValidators(5);
            vm.prank(coinbase);
            windpayValidatorSet.updateValidatorSetV2(consensusAddrs, votingPowers, voteAddrs);

            address[] memory valSet = windpayValidatorSet.getValidators();
            for (uint256 j; j < 5; ++j) {
                assertEq(valSet[j], consensusAddrs[j], "consensus address not equal");
                assertTrue(windpayValidatorSet.isCurrentValidator(consensusAddrs[j]), "the address should be a validator");
            }
        }
    }

    function testGetMiningValidatorsWith41Vals() public {
        (, address[] memory consensusAddrs, uint64[] memory votingPowers, bytes[] memory voteAddrs) =
            _batchCreateValidators(41);
        vm.prank(coinbase);
        windpayValidatorSet.updateValidatorSetV2(consensusAddrs, votingPowers, voteAddrs);

        address[] memory vals = windpayValidatorSet.getValidators();
        (address[] memory miningVals,) = windpayValidatorSet.getMiningValidators();

        uint256 count;
        uint256 _numOfCabinets;
        uint256 _maxNumOfWorkingCandidates = maxNumOfWorkingCandidates;
        if (numOfCabinets == 0) {
            _numOfCabinets = windpayValidatorSet.INIT_NUM_OF_CABINETS();
        } else {
            _numOfCabinets = numOfCabinets;
        }
        if ((vals.length - _numOfCabinets) < _maxNumOfWorkingCandidates) {
            _maxNumOfWorkingCandidates = vals.length - _numOfCabinets;
        }

        for (uint256 i; i < _numOfCabinets; ++i) {
            cabinets[vals[i]] = true;
        }
        for (uint256 i; i < _numOfCabinets; ++i) {
            if (!cabinets[miningVals[i]]) {
                ++count;
            }
        }
        assertGe(_maxNumOfWorkingCandidates, count);
        assertGe(count, 0);
    }

    function testDistributeAlgorithm() public {
        (
            address[] memory operatorAddrs,
            address[] memory consensusAddrs,
            uint64[] memory votingPowers,
            bytes[] memory voteAddrs
        ) = _batchCreateValidators(1);

        vm.startPrank(coinbase);
        windpayValidatorSet.updateValidatorSetV2(consensusAddrs, votingPowers, voteAddrs);

        address val = consensusAddrs[0];
        address deprecated = _getNextUserAddress();
        vm.deal(address(windpayValidatorSet), 0);

        for (uint256 i; i < 5; ++i) {
            windpayValidatorSet.deposit{ value: 1 ether }(val);
            windpayValidatorSet.deposit{ value: 1 ether }(deprecated);
            windpayValidatorSet.deposit{ value: 0.1 ether }(val);
            windpayValidatorSet.deposit{ value: 0.1 ether }(deprecated);
        }

        uint256 expectedBalance = _calcIncoming(11 ether);
        uint256 expectedIncoming = _calcIncoming(5.5 ether);
        uint256 balance = address(windpayValidatorSet).balance;
        uint256 incoming = windpayValidatorSet.totalInComing();
        assertEq(balance, expectedBalance);
        assertEq(incoming, expectedIncoming);

        vm.expectEmit(true, false, false, true, address(stakeHub));
        emit RewardDistributed(operatorAddrs[0], expectedIncoming);
        vm.expectEmit(false, false, false, true, address(windpayValidatorSet));
        emit systemTransfer(expectedBalance - expectedIncoming);
        vm.expectEmit(false, false, false, false, address(windpayValidatorSet));
        emit validatorSetUpdated();
        windpayValidatorSet.updateValidatorSetV2(consensusAddrs, votingPowers, voteAddrs);

        vm.stopPrank();
    }

    function testMassiveDistribute() public {
        (
            address[] memory operatorAddrs,
            address[] memory consensusAddrs,
            uint64[] memory votingPowers,
            bytes[] memory voteAddrs
        ) = _batchCreateValidators(41);

        vm.startPrank(coinbase);
        windpayValidatorSet.updateValidatorSetV2(consensusAddrs, votingPowers, voteAddrs);

        for (uint256 i; i < 41; ++i) {
            windpayValidatorSet.deposit{ value: 1 ether }(consensusAddrs[i]);
        }
        vm.stopPrank();

        (operatorAddrs, consensusAddrs, votingPowers, voteAddrs) = _batchCreateValidators(41);
        vm.prank(coinbase);
        windpayValidatorSet.updateValidatorSetV2(consensusAddrs, votingPowers, voteAddrs);
    }

    function testDistributeFinalityReward() public {
        address[] memory addrs = new address[](20);
        uint256[] memory weights = new uint256[](20);
        address[] memory vals = windpayValidatorSet.getValidators();
        for (uint256 i; i < 10; ++i) {
            addrs[i] = vals[i];
            weights[i] = 1;
        }

        for (uint256 i = 10; i < 20; ++i) {
            vals[i] = _getNextUserAddress();
            weights[i] = 1;
        }

        // failed case
        uint256 ceil = windpayValidatorSet.MAX_SYSTEM_REWARD_BALANCE();
        vm.deal(address(systemReward), ceil - 1);
        vm.expectRevert(bytes("the message sender must be the block producer"));
        windpayValidatorSet.distributeFinalityReward(addrs, weights);

        vm.startPrank(coinbase);
        windpayValidatorSet.distributeFinalityReward(addrs, weights);
        vm.expectRevert(bytes("can not do this twice in one block"));
        windpayValidatorSet.distributeFinalityReward(addrs, weights);

        // success case
        // balanceOfSystemReward > MAX_SYSTEM_REWARD_BALANCE
        uint256 reward = 1 ether;
        vm.deal(address(systemReward), ceil + reward);
        vm.roll(block.number + 1);

        uint256 expectReward = reward / 20;
        vm.expectEmit(true, false, false, true, address(windpayValidatorSet));
        emit finalityRewardDeposit(addrs[0], expectReward);
        vm.expectEmit(true, false, false, true, address(windpayValidatorSet));
        emit finalityRewardDeposit(addrs[9], expectReward);
        vm.expectEmit(true, false, false, true, address(windpayValidatorSet));
        emit deprecatedFinalityRewardDeposit(addrs[10], expectReward);
        vm.expectEmit(true, false, false, true, address(windpayValidatorSet));
        emit deprecatedFinalityRewardDeposit(addrs[19], expectReward);
        windpayValidatorSet.distributeFinalityReward(addrs, weights);
        assertEq(address(systemReward).balance, ceil);

        // cannot exceed MAX_REWARDS
        uint256 cap = systemReward.MAX_REWARDS();
        vm.deal(address(systemReward), ceil + cap * 2);
        vm.roll(block.number + 1);

        expectReward = cap / 20;
        vm.expectEmit(true, false, false, true, address(windpayValidatorSet));
        emit finalityRewardDeposit(addrs[0], expectReward);
        vm.expectEmit(true, false, false, true, address(windpayValidatorSet));
        emit finalityRewardDeposit(addrs[9], expectReward);
        vm.expectEmit(true, false, false, true, address(windpayValidatorSet));
        emit deprecatedFinalityRewardDeposit(addrs[10], expectReward);
        vm.expectEmit(true, false, false, true, address(windpayValidatorSet));
        emit deprecatedFinalityRewardDeposit(addrs[19], expectReward);
        windpayValidatorSet.distributeFinalityReward(addrs, weights);
        assertEq(address(systemReward).balance, ceil + cap);

        vm.stopPrank();
    }

    function _calcIncoming(uint256 value) internal view returns (uint256 incoming) {
        uint256 turnLength = windpayValidatorSet.getTurnLength();
        uint256 systemRewardAntiMEVRatio = windpayValidatorSet.systemRewardAntiMEVRatio();
        uint256 systemRewardRatio = systemRewardBaseRatio;
        if (turnLength > 1 && systemRewardAntiMEVRatio > 0) {
            systemRewardRatio += systemRewardAntiMEVRatio * (block.number % turnLength) / (turnLength - 1);
        }
        uint256 toSystemReward = (value * systemRewardRatio) / systemRewardRatioScale;
        uint256 toBurn = (value * burnRatio) / burnRatioScale;
        incoming = value - toSystemReward - toBurn;
    }
}
