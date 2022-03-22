// SPDX-License-Identifier: MIT

pragma solidity 0.7.5;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IwsFHM {
    function sFHMValue(uint _amount) external view returns (uint);
}

interface IRewardsHolder {
    function newTick() external;
}

interface IVotingEscrow {
    function balanceOfVotingToken(address _owner) external view returns (uint);
}

/// @title Double staking vault for FantOHM
/// @author pwntr0n
/// @notice With this staking vault you can receive rebases from 3,3 staking and rewards for 6,6 double staking
contract StakingStaking is Ownable, AccessControl, ReentrancyGuard, IVotingEscrow {

    using SafeERC20 for IERC20;
    using SafeMath for uint;

    /// @dev ACL role for borrower contract to whitelist call our methods
    bytes32 public constant BORROWER_ROLE = keccak256("BORROWER_ROLE");

    /// @dev ACL role for calling newSample() from RewardsHolder contract
    bytes32 public constant REWARDS_ROLE = keccak256("REWARDS_ROLE");

    address public immutable wsFHM;
    address public immutable DAO;
    address public rewardsHolder;
    uint public noFeeBlocks; // 30 days in blocks
    uint public unstakeFee; // 100 means 1%
    uint public claimPageSize; // maximum iteration threshold

    // actual number of wsFHM staking, which is user staking pool
    uint public totalStaking;
    // actual number of wsFHM transferred during sample ticks which were not claimed to any user, which is rewards pool
    uint public totalPendingClaim;
    // actual number of wsFHM borrowed
    uint public totalBorrowed;

    bool public pauseNewStakes;
    bool public useWhitelist;
    bool public enableEmergencyWithdraw;
    bool private initCalled;

    /// @notice data structure holding info about all stakers
    struct UserInfo {
        uint staked; // absolute number of wsFHM user is staking or rewarded

        uint borrowed; // absolute number of wsFHM user agains user has borrowed something

        uint lastStakeBlockNumber; // time of last stake from which is counting noFeeDuration
        uint lastClaimIndex; // index in rewardSamples last claimed

        mapping(address => uint) allowances;
    }

    /// @notice data structure holding info about all rewards gathered during time
    struct SampleInfo {
        uint blockNumber; // time of newSample tick
        uint timestamp; // time of newSample tick as unix timestamp

        uint totalRewarded; // absolute number of wsFHM transferred during newSample

        uint tvl; // wsFHM supply staking contract is holding from which rewards will be dispersed
    }

    mapping(address => bool) public whitelist;

    mapping(address => UserInfo) public userInfo;

    SampleInfo[] public rewardSamples;

    /* ///////////////////////////////////////////////////////////////
                                EVENTS
    ////////////////////////////////////////////////////////////// */

    /// @notice deposit event
    /// @param _from user who triggered the deposit
    /// @param _to user who is able to withdraw the deposited tokens
    /// @param _value deposited wsFHM value
    /// @param _lastStakeBlockNumber block number of deposit
    event StakingDeposited(address indexed _from, address indexed _to, uint _value, uint _lastStakeBlockNumber);

    /// @notice withdraw event
    /// @param _owner user who triggered the withdrawal
    /// @param _to user who received the withdrawn tokens
    /// @param _unstaked amount in wsFHM token to be withdrawn
    /// @param _transferred amount in wsFHM token actually withdrawn - potential fee was applied
    /// @param _unstakeBlock block number of event generated
    event StakingWithdraw(address indexed _owner, address indexed _to, uint _unstaked, uint _transferred, uint _unstakeBlock);

    /// @notice new rewards were sampled and prepared for claim
    /// @param _blockNumber  block number of event generated
    /// @param _blockTimestamp  block timestamp of event generated
    /// @param _rewarded  block timestamp of event generated
    /// @param _tvl  wsFHM supply in the time of sample
    event RewardSampled(uint _blockNumber, uint _blockTimestamp, uint _rewarded, uint _tvl);

    /// @notice reward claimed during one claim() method
    /// @param _wallet  user who triggered the claim
    /// @param _startClaimIndex first rewards which were claimed
    /// @param _lastClaimIndex last rewards which were claimed
    /// @param _claimed how many wsFHM claimed
    event RewardClaimed(address indexed _wallet, uint indexed _startClaimIndex, uint indexed _lastClaimIndex, uint _claimed);

    /// @notice token transferred inside vault
    /// @param _from  user who triggered the transfer
    /// @param _to user to which is transferring to
    /// @param _amount amount in wrapped token to transfer
    event TokenTransferred(address indexed _from, address indexed _to, uint _amount);

    /// @notice approve borrow contract for 9,9 borrowing against
    /// @param _owner user who triggered approval
    /// @param _spender user who has rights to call borrow and return borrow or liquidate borrow
    /// @param _value how much he can borrow against
    event BorrowApproved(address indexed _owner, address indexed _spender, uint _value);

    /// @notice borrow contract transferred wsFHM of owner from the vault
    /// @param _owner user whos account is used
    /// @param _spender calling smart contract
    /// @param _borrowed how borrowed against
    /// @param _blockNumber block number of event generated
    event Borrowed(address indexed _owner, address indexed _spender, uint _borrowed, uint _blockNumber);

    /// @notice borrow contract returned wsFHM to owner to the vault
    /// @param _owner user whos account is used
    /// @param _spender calling smart contract
    /// @param _returned how much returned from borrow against
    /// @param _blockNumber block number of event generated
    event BorrowReturned(address indexed _owner, address indexed _spender, uint _returned, uint _blockNumber);

    /// @notice borrow contract liquidated wsFHM to owner to the vault
    /// @param _owner user whos account is used
    /// @param _spender calling smart contract
    /// @param _liquidated how much was lost during borrow against
    /// @param _blockNumber block number of event generated
    event BorrowLiquidated(address indexed _owner, address indexed _spender, uint _liquidated, uint _blockNumber);

    /// @notice emergency token transferred
    /// @param _token ERC20 token
    /// @param _recipient recipient of transaction
    /// @param _amount token amount
    event EmergencyTokenRecovered(address indexed _token, address indexed _recipient, uint _amount);

    /// @notice emergency withdraw of unclaimed rewards
    /// @param _recipient recipient of transaction
    /// @param _rewarded wsFHM amount of unclaimed rewards transferred
    event EmergencyRewardsWithdraw(address indexed _recipient, uint _rewarded);

    /// @notice emergency withdraw of ETH
    /// @param _recipient recipient of transaction
    /// @param _amount ether value of transaction
    event EmergencyEthRecovered(address indexed _recipient, uint _amount);

    constructor(address _wsFHM, address _DAO) {
        require(_wsFHM != address(0));
        wsFHM = _wsFHM;
        require(_DAO != address(0));
        DAO = _DAO;

        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @notice suggested values:
    /// @param _noFeeBlocks - 30 days in blocks
    /// @param _unstakeFee - 3000 aka 30%
    /// @param _claimPageSize - 100/1000
    /// @param _useWhitelist - false (we can set it when we will test on production)
    /// @param _pauseNewStakes - false (you can set as some emergency leave precaution)
    /// @param _enableEmergencyWithdraw - false (you can set as some emergency leave precaution)
    function setParameters(address _rewardsHolder, uint _noFeeBlocks, uint _unstakeFee, uint _claimPageSize, bool _useWhitelist, bool _pauseNewStakes, bool _enableEmergencyWithdraw) public onlyOwner {
        rewardsHolder = _rewardsHolder;
        noFeeBlocks = _noFeeBlocks;
        unstakeFee = _unstakeFee;
        claimPageSize = _claimPageSize;
        useWhitelist = _useWhitelist;
        pauseNewStakes = _pauseNewStakes;
        enableEmergencyWithdraw = _enableEmergencyWithdraw;

        _setupRole(REWARDS_ROLE, _rewardsHolder);
        _setupRole(REWARDS_ROLE, msg.sender);

        if (!initCalled) {
            newSample(0);
            initCalled = true;
        }
    }

    function modifyWhitelist(address user, bool add) external onlyOwner {
        if (add) {
            require(!whitelist[user], "ALREADY_IN_WHITELIST");
            whitelist[user] = true;
        } else {
            require(whitelist[user], "NOT_IN_WHITELIST");
            delete whitelist[user];
        }
    }

    /// @notice Insert _amount to the pool, add to your share, need to claim everything before new stake
    /// @param _to user onto which account we want to transfer money
    /// @param _amount how much wsFHM user wants to deposit
    function deposit(address _to, uint _amount) public nonReentrant {
        // temporary disable new stakes, but allow to call claim and unstake
        require(!pauseNewStakes, "PAUSED");
        // allow only whitelisted contracts
        if (useWhitelist) require(whitelist[msg.sender], "SENDER_IS_NOT_IN_WHITELIST");

        doClaim(_to, claimPageSize);

        // unsure that user claim everything before stake again
        require(userInfo[_to].lastClaimIndex == rewardSamples.length - 1, "CLAIM_PAGE_TOO_SMALL");

        // erc20 transfer of staked tokens
        IERC20(wsFHM).safeTransferFrom(msg.sender, address(this), _amount);

        uint staked = userInfo[_to].staked.add(_amount);

        // persist it
        UserInfo storage info = userInfo[_to];
        info.staked = staked;
        info.lastStakeBlockNumber = block.number;

        totalStaking = totalStaking.add(_amount);

        // and record in history
        emit StakingDeposited(msg.sender, _to, _amount, info.lastStakeBlockNumber);
    }

    /// @notice Return current TVL of staking contract
    /// @return totalStaking plus totalPendingClaim even with amount borrowed against
    function totalValueLocked() public view returns (uint) {
        return totalStaking.add(totalPendingClaim);
    }

    /// @notice Returns the amount of underlying tokens that idly sit in the Vault.
    /// @return The amount of underlying tokens that sit idly in the Vault.
    function totalHoldings() public view returns (uint) {
        return IERC20(wsFHM).balanceOf(address(this));
    }

    /// @notice underlying token used for accounting
    function underlying() public view returns (address) {
        return wsFHM;
    }

    /// @notice last rewards to stakers
    /// @dev APY => 100 * (1 + <actualRewards> / <totalValueLocked>)^(365 * <rebases per day>)
    /// @return rewards for last sample
    function actualRewards() public view returns (uint) {
        return rewardSamples[rewardSamples.length - 1].totalRewarded;
    }

    /// @notice Return user balance
    /// @return 1 - staked and to claim from rewards, 2 - withdrawable, 3 - borrowed
    function userBalance(address _user) public view returns (uint, uint, uint) {
        UserInfo storage info = userInfo[_user];

        // count amount to withdraw from staked tokens except borrowed tokens
        uint toWithdraw = 0;
        (uint allClaimable,) = claimable(_user, claimPageSize);
        uint stakedAndToClaim = info.staked.add(allClaimable);
        if (stakedAndToClaim >= info.borrowed) {
            toWithdraw = stakedAndToClaim.sub(info.borrowed);
        }

        uint withdrawable = getWithdrawableBalance(info.lastStakeBlockNumber, toWithdraw);

        return (stakedAndToClaim, withdrawable, info.borrowed);
    }

    /// @notice safety check if user need to manually call claim to see additional rewards
    /// @param _user owner
    /// @return true if need to manually call claim or borrow/return/liquidate before additional deposit/withdraw
    function needToClaim(address _user) external view returns (bool) {
        UserInfo storage info = userInfo[_user];
        return info.lastClaimIndex + claimPageSize < rewardSamples.length;
    }

    /// @notice Returns a user's Vault balance in underlying tokens.
    /// @param _owner The user to get the underlying balance of.
    /// @return The user's Vault balance in underlying tokens.
    function balanceOfUnderlying(address _owner) public view returns (uint) {
        (uint stakedAndToClaim,,) = userBalance(_owner);
        return stakedAndToClaim;
    }

    /// @notice This method shows staked token balance from wrapped token balance even from rewards
    /// @dev Should be used in snapshot.eth strategy contract call
    /// @param _owner The user to get the underlying balance of.
    /// @return Balance in staked token usefull for voting escrow
    function balanceOfVotingToken(address _owner) external override view returns (uint) {
        (uint stakedAndToClaim,,) = userBalance(_owner);
        return IwsFHM(wsFHM).sFHMValue(stakedAndToClaim);
    }

    function getWithdrawableBalance(uint lastStakeBlockNumber, uint _balanceWithdrawable) private view returns (uint) {
        if (block.number < lastStakeBlockNumber.add(noFeeBlocks)) {
            uint fee = _balanceWithdrawable.mul(unstakeFee).div(10 ** 4);
            _balanceWithdrawable = _balanceWithdrawable.sub(fee);
        }
        return _balanceWithdrawable;
    }

    /// @notice Rewards holder accumulated enough balance during its period to create new sample, Record our current staking TVL
    /// @param _rewarded wsFHM amount rewarded
    function newSample(uint _rewarded) public {
        require(hasRole(REWARDS_ROLE, msg.sender), "MISSING_REWARDS_ROLE");

        // transfer balance from rewards holder
        if (_rewarded > 0) IERC20(wsFHM).safeTransferFrom(msg.sender, address(this), _rewarded);

        uint tvl = totalValueLocked();

        rewardSamples.push(SampleInfo({
        // remember time data
        blockNumber : block.number,
        timestamp : block.timestamp,

        // rewards size
        totalRewarded : _rewarded,

        // holders snapshot based on staking and pending claim wsFHM
        tvl : tvl
        }));

        // count total value to be claimed
        totalPendingClaim = totalPendingClaim.add(_rewarded);

        // and record in history
        emit RewardSampled(block.number, block.timestamp, _rewarded, tvl);
    }

    /// @notice Counts claimable tokens from totalPendingClaim tokens for given user
    /// @param _user claiming user
    /// @param _claimPageSize page size for iteration loop
    /// @return claimable amount up to the page size and last claim index
    function claimable(address _user, uint _claimPageSize) private view returns (uint, uint){
        UserInfo storage info = userInfo[_user];

        uint lastClaimIndex = info.lastClaimIndex;
        // last item already claimed
        if (lastClaimIndex == rewardSamples.length - 1) return (0, rewardSamples.length - 1);

        // start claiming with wsFHM staking previously
        uint allClaimed = 0;

        // new user considered as claimed last sample
        if (info.lastStakeBlockNumber == 0) {
            lastClaimIndex = rewardSamples.length - 1;
        } else {
            uint staked = info.staked;
            uint startIndex = lastClaimIndex + 1;
            // page size is either _claimPageSize or the rest
            uint endIndex = Math.min(lastClaimIndex + _claimPageSize, rewardSamples.length - 1);

            if (staked > 0) {
                for (uint i = startIndex; i <= endIndex; i++) {
                    // compute share from current TVL, which means not yet claimed rewards are _counted_ to the APY
                    if (rewardSamples[i].tvl > 0) {
                        uint claimed = 0;
                        // 40 * 10 / 20000
                        uint share = staked.add(allClaimed);
                        uint wsfhm = rewardSamples[i].totalRewarded.mul(share);
                        claimed = wsfhm.div(rewardSamples[i].tvl);
                        allClaimed = allClaimed.add(claimed);
                    }
                }
            }
            lastClaimIndex = endIndex;
        }

        return (allClaimed, lastClaimIndex);
    }

    function claim(uint _claimPageSize) external nonReentrant {
        doClaim(msg.sender, _claimPageSize);
    }

    /// @notice Claim unprocessed rewards to belong to userInfo staking amount with possibility to choose _claimPageSize
    /// @param _user claiming user
    /// @param _claimPageSize page size for iteration loop
    function doClaim(address _user, uint _claimPageSize) private {
        // clock new tick
        IRewardsHolder(rewardsHolder).newTick();

        UserInfo storage info = userInfo[_user];

        // last item already claimed
        if (info.lastClaimIndex == rewardSamples.length - 1) return;

        // otherwise collect rewards
        uint startIndex = info.lastClaimIndex + 1;
        (uint allClaimed, uint lastClaimIndex) = claimable(_user, _claimPageSize);

        // persist it
        info.staked = info.staked.add(allClaimed);
        info.lastClaimIndex = lastClaimIndex;

        totalStaking = totalStaking.add(allClaimed);
        // remove it from total balance if is not last one
        if (totalPendingClaim > allClaimed) {
            totalPendingClaim = totalPendingClaim.sub(allClaimed);
        } else {
            // wsfhm balance of last one is the same, so gons should be rounded
            require(totalPendingClaim == allClaimed, "LAST_USER_NEED_BALANCE");
            totalPendingClaim = 0;
        }

        // and record in history
        emit RewardClaimed(_user, startIndex, info.lastClaimIndex, allClaimed);
    }

    /// @notice Unstake _amount from staking pool. Automatically call claim.
    /// @param _to user who will receive withdraw amount
    /// @param _amount amount to withdraw
    /// @param _force force withdraw without claiming rewards
    function withdraw(address _to, uint256 _amount, bool _force) public nonReentrant {
        address _owner = msg.sender;
        // auto claim before unstake
        if (!_force) doClaim(_owner, claimPageSize);

        UserInfo storage info = userInfo[_owner];

        // unsure that user claim everything before unstaking
        require(info.lastClaimIndex == rewardSamples.length - 1 || _force, "CLAIM_PAGE_TOO_SMALL");

        // count amount to withdraw from staked except borrowed
        uint maxToUnstake = info.staked.sub(info.borrowed);
        require(_amount <= maxToUnstake, "NOT_ENOUGH_USER_TOKENS");

        uint transferring = getWithdrawableBalance(info.lastStakeBlockNumber, _amount);
        // and more than we have
        require(transferring <= totalStaking, "NOT_ENOUGH_TOKENS_IN_POOL");

        info.staked = info.staked.sub(_amount);
        if (info.staked == 0) {
            // if unstaking everything just delete whole record
            delete userInfo[_owner];
        }

        // remove it from total balance
        if (totalStaking > _amount) {
            totalStaking = totalStaking.sub(_amount);
        } else {
            // wsfhm balance of last one is the same, so wsfhm should be rounded
            require(totalStaking == _amount, "LAST_USER_NEED_BALANCE");
            totalStaking = 0;
        }

        // actual erc20 transfer
        IERC20(wsFHM).safeTransfer(_to, transferring);

        // and send fee to DAO
        uint fee = _amount.sub(transferring);
        if (fee > 0) {
            IERC20(wsFHM).safeTransfer(DAO, fee);
        }

        // and record in history
        emit StakingWithdraw(_owner, _to, _amount, transferring, block.number);
    }

    /// @notice transfers amount to different user with preserving lastStakedBlock
    /// @param _to user transferring amount to
    /// @param _amount wsfhm amount
    function transfer(address _to, uint _amount) external nonReentrant {
        // need to claim before any operation with staked amounts
        // use half of the page size to have same complexity
        uint halfPageSize = claimPageSize.div(2);
        doClaim(msg.sender, halfPageSize);
        doClaim(_to, halfPageSize);

        // subtract from caller
        UserInfo storage fromInfo = userInfo[msg.sender];
        require(fromInfo.staked.sub(fromInfo.borrowed) >= _amount, "NOT_ENOUGH_USER_TOKENS");
        fromInfo.staked = fromInfo.staked.sub(_amount);

        // add it to the callee
        UserInfo storage toInfo = userInfo[_to];
        toInfo.staked = toInfo.staked.add(_amount);
        // act as normal deposit()
        toInfo.lastStakeBlockNumber = Math.max(fromInfo.lastStakeBlockNumber, toInfo.lastStakeBlockNumber);

        // and record in history
        emit TokenTransferred(msg.sender, _to, _amount);
    }


    /* ///////////////////////////////////////////////////////////////
                          BORROWING FUNCTIONS
    ////////////////////////////////////////////////////////////// */

    /// @notice approve _spender to do anything with _amount of tokens for current caller user
    /// @param _spender who will have right to do whatever he wants with _amount of user's money
    /// @param _amount approved amount _spender can withdraw
    function approve(address _spender, uint _amount) external {
        address user = msg.sender;
        UserInfo storage info = userInfo[user];
        info.allowances[_spender] = _amount;

        emit BorrowApproved(user, _spender, _amount);
    }

    /// @notice check approve result, how much is approved for _owner and arbitrary _spender
    /// @param _owner who gives right to the _spender
    /// @param _spender who will have right to do whatever he wants with _amount of user's money
    function allowance(address _owner, address _spender) public view returns (uint) {
        UserInfo storage info = userInfo[_owner];
        return info.allowances[_spender];
    }

    /// @notice allow to borrow asset against wsFHM collateral which are staking in this pool.
    /// You are able to borrow up to usd worth of staked + claimed tokens
    /// @param _user from which account
    /// @param _amount how much tokens _user wants to borrow against
    function borrow(address _user, uint _amount) external nonReentrant {
        require(hasRole(BORROWER_ROLE, msg.sender), "MISSING_BORROWER_ROLE");

        // temporary disable borrows, but allow to call returnBorrow
        require(!pauseNewStakes, "PAUSED");

        uint approved = allowance(_user, msg.sender);
        require(approved >= _amount, "NOT_ENOUGH_BALANCE");

        // auto claim before borrow
        // but don't enforce to be claimed all
        doClaim(_user, claimPageSize);

        UserInfo storage info = userInfo[_user];

        info.borrowed = info.borrowed.add(_amount);

        // refresh allowance
        info.allowances[msg.sender] = info.allowances[msg.sender].sub(_amount);

        // cannot borrow what is not mine
        require(info.borrowed <= info.staked, "NOT_ENOUGH_USER_TOKENS");
        // and more than we have staking or claimed
        uint availableToBorrow = totalStaking.sub(totalBorrowed);
        require(_amount <= availableToBorrow, "NOT_ENOUGH_POOL_TOKENS");

        // add it from total balance
        totalBorrowed = totalBorrowed.add(_amount);

        // erc20 transfer of staked tokens
        IERC20(wsFHM).safeTransfer(msg.sender, _amount);

        // and record in history
        emit Borrowed(_user, msg.sender, _amount, block.number);
    }

    /// @notice return borrowed staked tokens
    /// @param _user from which account
    /// @param _amount how much tokens _user wants to return
    function returnBorrow(address _user, uint _amount) external nonReentrant {
        require(hasRole(BORROWER_ROLE, msg.sender), "MISSING_BORROWER_ROLE");

        // erc20 transfer of staked tokens
        IERC20(wsFHM).safeTransferFrom(msg.sender, address(this), _amount);

        // auto claim returnBorrow borrow
        // but don't enforce to be claimed all
        doClaim(_user, claimPageSize);

        UserInfo storage info = userInfo[_user];

        uint returningBorrowed = _amount;
        // return less then borrow this turn
        if (info.borrowed >= _amount) {
            info.borrowed = info.borrowed.sub(_amount);
        }
        // repay all plus give profit back
        else {
            returningBorrowed = info.borrowed;
            uint toStake = _amount.sub(returningBorrowed);
            info.staked = info.staked.add(toStake);
            info.borrowed = 0;
            totalStaking = totalStaking.add(toStake);
        }

        // subtract it from total balance
        if (totalBorrowed > returningBorrowed) {
            totalBorrowed = totalBorrowed.sub(returningBorrowed);
        } else {
            totalBorrowed = 0;
        }

        // and record in history
        emit BorrowReturned(_user, msg.sender, _amount, block.number);
    }

    /// @notice liquidation of borrowed staked tokens
    /// @param _user from which account
    /// @param _amount how much tokens _user wants to liquidate
    function liquidateBorrow(address _user, uint _amount) external nonReentrant {
        require(hasRole(BORROWER_ROLE, msg.sender), "MISSING_BORROWER_ROLE");

        // auto claim returnBorrow borrow
        // but don't enforce to be claimed all
        doClaim(_user, claimPageSize);

        UserInfo storage info = userInfo[_user];

        // liquidate less or equal then borrow this turn
        if (info.borrowed >= _amount) {
            // 1. subs from user staked
            if (info.staked > _amount) {
                info.staked = info.staked.sub(_amount);
            } else {
                info.staked = 0;
            }

            // 2. subs from total staking
            if (totalStaking > _amount) {
                totalStaking = totalStaking.sub(_amount);
            } else {
                totalStaking = 0;
            }

            // 3. subs total borrowed
            if (totalBorrowed > _amount) {
                totalBorrowed = totalBorrowed.sub(_amount);
            } else {
                totalBorrowed = 0;
            }

            // 4. subs from user borrowed
            info.borrowed = info.borrowed.sub(_amount);
        }
        // liquidate all plus take a loss
        else {
            uint toTakeLoss = _amount.sub(info.borrowed);

            // 1. subs from user staked
            if (info.staked > toTakeLoss) {
                info.staked = info.staked.sub(toTakeLoss);
            } else {
                info.staked = 0;
            }

            // 2. subs from total staking
            if (totalStaking > toTakeLoss) {
                totalStaking = totalStaking.sub(toTakeLoss);
            } else {
                totalStaking = 0;
            }

            // 3. subs from total borrowed
            if (totalBorrowed > info.borrowed) {
                totalBorrowed = totalBorrowed.sub(info.borrowed);
            } else {
                totalBorrowed = 0;
            }

            // 4. subs from borrowed
            info.borrowed = 0;
        }

        // and record in history
        emit BorrowLiquidated(_user, msg.sender, _amount, block.number);
    }

    /* ///////////////////////////////////////////////////////////////
                           EMERGENCY FUNCTIONS
    ////////////////////////////////////////////////////////////// */

    /// @notice emergency withdraw of user holding
    function emergencyWithdraw() external {
        require(enableEmergencyWithdraw, "EMERGENCY_WITHDRAW_NOT_ENABLED");

        UserInfo storage info = userInfo[msg.sender];

        uint toWithdraw = info.staked.sub(info.borrowed);

        // clear the data
        info.staked = info.staked.sub(toWithdraw);

        // repair total values
        if (totalStaking >= toWithdraw) {
            totalStaking = totalStaking.sub(toWithdraw);
        } else {
            // wsfhm balance of last one is the same, so gons should be rounded
            require(totalStaking == toWithdraw, "Last user emergency withdraw needs balance");
            totalStaking = 0;
        }

        // erc20 transfer
        IERC20(wsFHM).safeTransfer(msg.sender, toWithdraw);

        // and record in history
        emit StakingWithdraw(msg.sender, msg.sender, toWithdraw, toWithdraw, block.number);
    }

    /// @dev Once called, any user who not claimed cannot claim/withdraw, should be used only in emergency.
    function emergencyWithdrawRewards() external onlyOwner {
        require(enableEmergencyWithdraw, "EMERGENCY_WITHDRAW_NOT_ENABLED");

        // repair total values
        uint amount = totalPendingClaim;
        totalPendingClaim = 0;

        // erc20 transfer
        IERC20(wsFHM).safeTransfer(DAO, amount);

        emit EmergencyRewardsWithdraw(DAO, amount);
    }

    /// @notice Been able to recover any token which is sent to contract by mistake
    /// @param token erc20 token
    function emergencyRecoverToken(address token) external virtual onlyOwner {
        require(token != wsFHM);

        uint amount = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(DAO, amount);

        emit EmergencyTokenRecovered(token, DAO, amount);
    }

    /// @notice Been able to recover any ftm/movr token sent to contract by mistake
    function emergencyRecoverEth() external virtual onlyOwner {
        uint amount = address(this).balance;

        payable(DAO).transfer(amount);

        emit EmergencyEthRecovered(DAO, amount);
    }

    /// @notice grants borrower role to given _account
    /// @param _account borrower contract
    function grantRoleBorrower(address _account) external {
        grantRole(BORROWER_ROLE, _account);
    }

    /// @notice revoke borrower role to given _account
    /// @param _account borrower contract
    function revokeRoleBorrower(address _account) external {
        revokeRole(BORROWER_ROLE, _account);
    }

    /// @notice grants rewards role to given _account
    /// @param _account rewards contract
    function grantRoleRewards(address _account) external {
        grantRole(REWARDS_ROLE, _account);
    }

    /// @notice revoke rewards role to given _account
    /// @param _account rewards contract
    function revokeRoleRewards(address _account) external {
        revokeRole(REWARDS_ROLE, _account);
    }

    /* ///////////////////////////////////////////////////////////////
                            RECEIVE ETHER LOGIC
    ////////////////////////////////////////////////////////////// */

    /// @dev Required for the Vault to receive unwrapped ETH.
    receive() external payable {}

}
