// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.17;

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/structs/DoubleEndedQueueUpgradeable.sol";

import "./SystemV2.sol";
import "./interface/0.8.x/IStakeHub.sol";

contract StakeCredit is SystemV2, Initializable, ReentrancyGuardUpgradeable, ERC20Upgradeable {
    using CountersUpgradeable for CountersUpgradeable.Counter;
    using DoubleEndedQueueUpgradeable for DoubleEndedQueueUpgradeable.Bytes32Deque;

    /*----------------- constants -----------------*/
    uint256 private constant COMMISSION_RATE_BASE = 10_000; // 100%

    /*----------------- errors -----------------*/
    // @notice signature: 0x2fe8dae9
    error ZeroTotalShares();
    // @notice signature: 0xf6ed9ce0
    error ZeroTotalPooledWind();
    // @notice signature: 0x8cd22d19
    error TransferNotAllowed();
    // @notice signature: 0x20287471
    error ApproveNotAllowed();
    // @notice signature: 0x858f9ae4
    error WrongInitContext();
    // @notice signature: 0x90b8ec18
    error TransferFailed();
    // @notice signature: 0x1f2a2005
    error ZeroAmount();
    // @notice signature: 0x9811e0c7
    error ZeroShares();
    // @notice signature: 0xf4d678b8
    error InsufficientBalance();
    // @notice signature: 0xad418937
    error NoUnbondRequest();
    // @notice signature: 0x0f363824
    error NoClaimableUnbondRequest();
    // @notice signature: 0xb19e9115
    error RequestExisted();

    /*----------------- storage -----------------*/
    address public validator; // validator's operator address
    uint256 public totalPooledWind; // total reward plus total WIND staked in the pool

    // hash of the unbond request => unbond request
    mapping(bytes32 => UnbondRequest) private _unbondRequests;
    // delegator address => unbond request queue(hash of the request)
    mapping(address => DoubleEndedQueueUpgradeable.Bytes32Deque) private _unbondRequestsQueue;
    // delegator address => personal unbond sequence
    mapping(address => CountersUpgradeable.Counter) private _unbondSequence;

    // day index => receivedReward
    mapping(uint256 => uint256) public rewardRecord;
    // day index => totalPooledWind
    mapping(uint256 => uint256) public totalPooledWindRecord;

    /*----------------- structs and events -----------------*/
    struct UnbondRequest {
        uint256 shares;
        uint256 windAmount;
        uint256 unlockTime;
    }

    event RewardReceived(uint256 rewardToAll, uint256 commission);

    /**
     * @notice only accept WIND from `StakeHub`
     */
    receive() external payable onlyStakeHub {
        uint256 index = block.timestamp / IStakeHub(STAKE_HUB_ADDR).BREATHE_BLOCK_INTERVAL();
        totalPooledWindRecord[index] = totalPooledWind;
        rewardRecord[index] += msg.value;
        totalPooledWind += msg.value;
    }

    /*----------------- init -----------------*/
    /*
     * @param _validator validator's operator address
     * @param _moniker validator's moniker
     */
    function initialize(address _validator, string calldata _moniker) external payable initializer onlyStakeHub {
        string memory name_ = string.concat("Stake ", _moniker, " Credit");
        string memory symbol_ = string.concat("st", _moniker);
        __ERC20_init_unchained(name_, symbol_);
        __ReentrancyGuard_init_unchained();

        validator = _validator;

        _bootstrapInitialHolder(msg.value);
    }

    /*----------------- external functions -----------------*/
    /**
     * @param delegator the address of the delegator
     * @return shares the amount of shares minted
     */
    function delegate(
        address delegator
    ) external payable onlyStakeHub returns (uint256 shares) {
        if (msg.value == 0) revert ZeroAmount();
        shares = _mintAndSync(delegator, msg.value);
        if (shares == 0) revert ZeroShares();
    }

    /**
     * @param delegator the address of the delegator
     * @param shares the amount of shares to be undelegated
     * @return windAmount the amount of WIND to be unlocked
     */
    function undelegate(address delegator, uint256 shares) external onlyStakeHub returns (uint256 windAmount) {
        if (shares == 0) revert ZeroShares();
        if (shares > balanceOf(delegator)) revert InsufficientBalance();

        // add to the queue
        windAmount = _burnAndSync(delegator, shares);
        uint256 unlockTime = block.timestamp + IStakeHub(STAKE_HUB_ADDR).unbondPeriod();
        UnbondRequest memory request = UnbondRequest({ shares: shares, windAmount: windAmount, unlockTime: unlockTime });
        bytes32 hash = keccak256(abi.encodePacked(delegator, _useSequence(delegator)));
        // the hash should not exist in the queue
        // this will not happen in normal cases
        if (_unbondRequests[hash].shares != 0) revert RequestExisted();
        _unbondRequests[hash] = request;
        _unbondRequestsQueue[delegator].pushBack(hash);
    }

    /**
     * @dev Unbond immediately without adding to the queue. Only for redelegate process.
     * @param delegator the address of the delegator
     * @param shares the amount of shares to be undelegated
     * @return windAmount the amount of WIND unlocked
     */
    function unbond(address delegator, uint256 shares) external onlyStakeHub returns (uint256 windAmount) {
        if (shares == 0) revert ZeroShares();
        if (shares > balanceOf(delegator)) revert InsufficientBalance();

        windAmount = _burnAndSync(delegator, shares);

        (bool success,) = STAKE_HUB_ADDR.call{ value: windAmount }("");
        if (!success) revert TransferFailed();
    }

    /**
     * @param delegator the address of the delegator
     * @param number the number of unbond requests to be claimed. 0 means claim all
     * @return _totalWindAmount the total amount of WIND claimed
     */
    function claim(address payable delegator, uint256 number) external onlyStakeHub nonReentrant returns (uint256) {
        // number == 0 means claim all
        // number should not exceed the length of the queue
        if (_unbondRequestsQueue[delegator].length() == 0) revert NoUnbondRequest();
        number = (number == 0 || number > _unbondRequestsQueue[delegator].length())
            ? _unbondRequestsQueue[delegator].length()
            : number;

        uint256 _totalWindAmount;
        while (number != 0) {
            bytes32 hash = _unbondRequestsQueue[delegator].front();
            UnbondRequest memory request = _unbondRequests[hash];
            if (block.timestamp < request.unlockTime) {
                break;
            }

            // remove from the queue
            _unbondRequestsQueue[delegator].popFront();

            _totalWindAmount += request.windAmount;
            --number;
        }
        if (_totalWindAmount == 0) revert NoClaimableUnbondRequest();

        uint256 _gasLimit = IStakeHub(STAKE_HUB_ADDR).transferGasLimit();
        (bool success,) = delegator.call{ gas: _gasLimit, value: _totalWindAmount }("");
        if (!success) revert TransferFailed();

        return _totalWindAmount;
    }

    /**
     * @dev Distribute the reward to the validator and all delegators. Only the `StakeHub` contract can call this function.
     * @param commissionRate the commission rate of the validator
     */
    function distributeReward(
        uint64 commissionRate
    ) external payable onlyStakeHub {
        uint256 windAmount = msg.value;
        uint256 _commission = (windAmount * uint256(commissionRate)) / COMMISSION_RATE_BASE;
        uint256 _reward = windAmount - _commission;

        uint256 index = block.timestamp / IStakeHub(STAKE_HUB_ADDR).BREATHE_BLOCK_INTERVAL();
        totalPooledWindRecord[index] = totalPooledWind;
        rewardRecord[index] += _reward;
        totalPooledWind += _reward;

        // mint commission to the validator
        _mintAndSync(validator, _commission);

        emit RewardReceived(_reward, _commission);
    }

    /**
     * @dev Slash the validator. Only the `StakeHub` contract can call this function.
     * @param slashWindAmount the amount of WIND to be slashed
     * @return realSlashWindAmount the real amount of WIND slashed
     */
    function slash(
        uint256 slashWindAmount
    ) external onlyStakeHub returns (uint256) {
        uint256 selfDelegation = balanceOf(validator);
        uint256 slashShares = getSharesByPooledWind(slashWindAmount);

        slashShares = slashShares > selfDelegation ? selfDelegation : slashShares;
        uint256 realSlashWindAmount = _burnAndSync(validator, slashShares);

        (bool success,) = SYSTEM_REWARD_ADDR.call{ value: realSlashWindAmount }("");
        if (!success) revert TransferFailed();

        return realSlashWindAmount;
    }

    /*----------------- view functions -----------------*/
    /**
     * @return the amount of shares that corresponds to `_windAmount` protocol-controlled WIND.
     */
    function getSharesByPooledWind(
        uint256 windAmount
    ) public view returns (uint256) {
        if (totalPooledWind == 0) revert ZeroTotalPooledWind();
        return (windAmount * totalSupply()) / totalPooledWind;
    }

    /**
     * @return the amount of WIND that corresponds to `_sharesAmount` token shares.
     */
    function getPooledWindByShares(
        uint256 shares
    ) public view returns (uint256) {
        if (totalSupply() == 0) revert ZeroTotalShares();
        return (shares * totalPooledWind) / totalSupply();
    }

    /**
     * @return the unbond request at _index.
     */
    function unbondRequest(address delegator, uint256 _index) public view returns (UnbondRequest memory) {
        bytes32 hash = _unbondRequestsQueue[delegator].at(_index);
        return _unbondRequests[hash];
    }

    /**
     * @return the total length of delegator's pending unbond queue.
     */
    function pendingUnbondRequest(
        address delegator
    ) public view returns (uint256) {
        return _unbondRequestsQueue[delegator].length();
    }

    /**
     * @return the total number of delegator's claimable unbond requests.
     */
    function claimableUnbondRequest(
        address delegator
    ) public view returns (uint256) {
        uint256 length = _unbondRequestsQueue[delegator].length();
        uint256 count;
        for (uint256 i; i < length; ++i) {
            bytes32 hash = _unbondRequestsQueue[delegator].at(i);
            UnbondRequest memory request = _unbondRequests[hash];
            if (block.timestamp >= request.unlockTime) {
                ++count;
            } else {
                break;
            }
        }
        return count;
    }

    /**
     * @return the sum of first `number` requests' WIND locked in delegator's unbond queue.
     */
    function lockedWinds(address delegator, uint256 number) public view returns (uint256) {
        // number == 0 means all
        // number should not exceed the length of the queue
        if (_unbondRequestsQueue[delegator].length() == 0) {
            return 0;
        }
        number = (number == 0 || number > _unbondRequestsQueue[delegator].length())
            ? _unbondRequestsQueue[delegator].length()
            : number;

        uint256 _totalWindAmount;
        for (uint256 i; i < number; ++i) {
            bytes32 hash = _unbondRequestsQueue[delegator].at(i);
            UnbondRequest memory request = _unbondRequests[hash];
            _totalWindAmount += request.windAmount;
        }
        return _totalWindAmount;
    }

    /**
     * @return the personal unbond sequence of the delegator.
     */
    function unbondSequence(
        address delegator
    ) public view returns (uint256) {
        return _unbondSequence[delegator].current();
    }

    /**
     * @return the total amount of WIND staked and reward of the delegator.
     */
    function getPooledWind(
        address account
    ) public view returns (uint256) {
        return getPooledWindByShares(balanceOf(account));
    }

    /*----------------- internal functions -----------------*/
    function _bootstrapInitialHolder(
        uint256 initAmount
    ) internal onlyInitializing {
        // check before mint
        uint256 toLock = IStakeHub(STAKE_HUB_ADDR).LOCK_AMOUNT();
        if (initAmount <= toLock || validator == address(0) || totalSupply() != 0) revert WrongInitContext();

        // mint initial tokens to the validator and lock some of them
        // shares is equal to the amount of WIND staked
        address deadAddress = IStakeHub(STAKE_HUB_ADDR).DEAD_ADDRESS();
        _mint(deadAddress, toLock);
        uint256 initShares = initAmount - toLock;
        _mint(validator, initShares);

        totalPooledWind = initAmount;
    }

    function _mintAndSync(address account, uint256 windAmount) internal returns (uint256 shares) {
        // shares here could be zero
        shares = getSharesByPooledWind(windAmount);
        _mint(account, shares);
        totalPooledWind += windAmount;
    }

    function _burnAndSync(address account, uint256 shares) internal returns (uint256 windAmount) {
        windAmount = getPooledWindByShares(shares);
        _burn(account, shares);
        totalPooledWind -= windAmount;
    }

    function _useSequence(
        address delegator
    ) internal returns (uint256 current) {
        CountersUpgradeable.Counter storage sequence = _unbondSequence[delegator];
        current = sequence.current();
        sequence.increment();
    }

    function _transfer(address, address, uint256) internal pure override {
        revert TransferNotAllowed();
    }

    function _approve(address, address, uint256) internal pure override {
        revert ApproveNotAllowed();
    }
}
