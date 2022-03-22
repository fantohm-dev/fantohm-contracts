// SPDX-License-Identifier: MIT

pragma solidity 0.7.5;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

interface IwsFHM {
    function wrap( uint _amount ) external returns ( uint );
}

interface IStaking {
    function stake(uint _amount, address _recipient) external returns (bool);

    function claim(address _recipient) external;
}

interface IStakingStaking {
    function newSample(uint _balance) external;
}

contract RewardsHolder is Ownable, AccessControl {
    using SafeMath for uint;

    /// @dev ACL role for staking pool contract to whitelist call our methods
    bytes32 public constant TICKER_ROLE = keccak256("TICKER_ROLE");

    address public immutable FHM;
    address public immutable sFHM;
    address public immutable wsFHM;
    address public immutable staking;
    address public stakingStaking;

    // when was last sample transfer of rewards
    uint public lastSampleBlockNumber;
    // once for how many blocks is next sample made
    uint public blocksPerSample;

    event RewardSample(uint timestamp, uint blockNumber, uint rewards);

    constructor(address _FHM, address _sFHM, address _wsFHM, address _staking) {
        require(_FHM != address(0));
        FHM = _FHM;
        require(_sFHM != address(0));
        sFHM = _sFHM;
        require(_wsFHM != address(0));
        wsFHM = _wsFHM;
        require(_staking != address(0));
        staking = _staking;

        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function setParameters(address _stakingStaking, uint _blocksPerSample) external onlyOwner {
        stakingStaking = _stakingStaking;
        blocksPerSample = _blocksPerSample;

        _setupRole(TICKER_ROLE, stakingStaking);
    }

    function _stakeAndConvert() private {
        // claim previous round from warmup
        IStaking(staking).claim(address(this));

        // wrap staked if got from warmup
        uint sfhmBalance = IERC20(sFHM).balanceOf(address(this));
        if (sfhmBalance > 0) {
            IERC20(sFHM).approve(wsFHM, sfhmBalance);
            IwsFHM(wsFHM).wrap(sfhmBalance);
        }

        // find if got rewards
        uint fhmRewards = IERC20(FHM).balanceOf(address(this));
        if (fhmRewards > 0) {
            // stake new round for warmup
            IERC20(FHM).approve(staking, fhmRewards);
            IStaking(staking).stake(fhmRewards, address(this));
        }
    }

    function newTick() external {
        require(hasRole(TICKER_ROLE, msg.sender), "MISSING_TICKER_ROLE");

        _stakeAndConvert();

        // not doing anything, waiting and gathering rewards
        if (lastSampleBlockNumber.add(blocksPerSample) > block.number) return;

        // perform new sample, remember staking pool supply back then

        // call new sample to transfer rewards
        uint rewards = IERC20(wsFHM).balanceOf(address(this));
        IERC20(wsFHM).approve(stakingStaking, rewards);
        IStakingStaking(stakingStaking).newSample(rewards);

        // remember last sample block
        lastSampleBlockNumber = block.number;

        // and record in history
        emit RewardSample(block.timestamp, block.number, rewards);
    }

    /// @notice grants ticker role to given _account
    /// @param _account ticker contract
    function grantRoleTicker(address _account) external {
        grantRole(TICKER_ROLE, _account);
    }

    /// @notice revoke ticker role to given _account
    /// @param _account ticker contract
    function revokeRoleTicker(address _account) external {
        revokeRole(TICKER_ROLE, _account);
    }
}
