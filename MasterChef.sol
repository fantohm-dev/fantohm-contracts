// SPDX-License-Identifier: MIT

pragma solidity 0.7.5;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Address.sol";

interface ITreasury {
    function deposit(uint _amount, address _token, uint _profit) external returns (uint send_);

    function valueOf(address _token, uint _amount) external view returns (uint value_);

    function mintRewards(address _recipient, uint _amount) external;
}

interface IMigratorChef {
    // Perform LP token migration from legacy PancakeSwap to CakeSwap.
    // Take the current LP token address and return the new LP token address.
    // Migrator should have full access to the caller's LP token.
    // Return the new LP token address.
    //
    // XXX Migrator must have allowance access to PancakeSwap LP tokens.
    // CakeSwap must mint EXACTLY the same amount of CakeSwap LP tokens or
    // else something bad will happen. Traditional PancakeSwap does not
    // do that so be careful!
    function migrate(IERC20 token) external returns (IERC20);
}

// MasterChef is the master of FHM. He can make FHM and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once FHM is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterChefV2 is Ownable, ReentrancyGuard, AccessControl {
    using SafeMath for uint;
    using SafeERC20 for IERC20;
    using Address for address;

    bytes32 public constant WHITELIST_WITHDRAW_ROLE = keccak256("WHITELIST_WITHDRAW_ROLE");

    // Info of each user.
    struct UserInfo {
        uint amount;            // How many LP tokens the user has provided.
        uint rewardDebt;        // Reward debt. See explanation below.
        bool whitelistWithdraw; // if true only whitelisted address can withdraw
        //
        // We do some fancy math here. Basically, any point in time, the amount of FHMs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accFhmPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accFhmPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }
    /// @notice Info of each pool.
    struct PoolInfo {
        IERC20 lpToken;         // Address of LP token contract.
        uint allocPoint;        // How many allocation points assigned to this pool. FHMs to distribute per block.
        uint lastRewardBlock;   // Last block number that FHMs distribution occurs.
        uint accFhmPerShare;    // Accumulated FHMs per share, times 1e12. See below.
        uint16 depositFeeBP;    // Deposit fee in basis points
        bool whitelistWithdraw; // when set on pool and deposited by whitelisted contract then only this contract can withdraw funds
    }

    // The FHM TOKEN!
    IERC20 public fhm;
    // Treasury address.
    address public treasuryAddress;
    // Fhm tokens created per block.
    // FIXME count fhm per block to each pool?
    uint public fhmPerBlock;
    // Bonus multiplier for early FHM makers.
    uint public constant BONUS_MULTIPLIER = 1;
    // Deposit Fee address
    address public feeAddress;
    // The migrator contract. It has a lot of power. Can only be set through governance (owner).
    IMigratorChef public migrator;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint public totalAllocPoint = 0;
    // The block number when FHM mining starts.
    uint public startBlock;

    event Deposit(address indexed user, uint indexed pid, uint amount);
    event Withdraw(address indexed user, uint indexed pid, uint amount);
    event Harvest(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint indexed pid, uint amount);
    event SetFeeAddress(address indexed user, address indexed newAddress);
    event SetTreasuryAddress(address indexed oldAddress, address indexed newAddress);
    event UpdateEmissionRate(address indexed user, uint fhmPerBlock);

    constructor(
        IERC20 _fhm,
        address _treasuryAddress,
        address _feeAddress,
        uint _fhmPerBlock,
        uint _startBlock
    ) {
        fhm = _fhm;
        treasuryAddress = _treasuryAddress;
        feeAddress = _feeAddress;
        fhmPerBlock = _fhmPerBlock;
        startBlock = _startBlock;

        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _setupRole(WHITELIST_WITHDRAW_ROLE, _msgSender());
    }

    function poolLength() external view returns (uint) {
        return poolInfo.length;
    }

    mapping(IERC20 => bool) public poolExistence;

    /// @notice Pool ID Tracker Mapper
    mapping(IERC20 => uint256) public poolIdForLpAddress;

    function getPoolIdForLpToken(IERC20 _lpToken) external view returns (uint256) {
        require(poolExistence[_lpToken] != false, "getPoolIdForLpToken: do not exist");
        return poolIdForLpAddress[_lpToken];
    }
    modifier nonDuplicated(IERC20 _lpToken) {
        require(poolExistence[_lpToken] == false, "nonDuplicated: duplicated");
        _;
    }

    /// @notice Add a new lp to the pool. Can only be called by the owner.
    function add(uint _allocPoint, IERC20 _lpToken, uint16 _depositFeeBP, bool _withUpdate, bool _whitelistWithdraw) public onlyOwner nonDuplicated(_lpToken) {
        require(_depositFeeBP <= 10000, "add: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        uint lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolExistence[_lpToken] = true;
        poolInfo.push(PoolInfo({
        lpToken : _lpToken,
        allocPoint : _allocPoint,
        lastRewardBlock : lastRewardBlock,
        accFhmPerShare : 0,
        depositFeeBP : _depositFeeBP,
        whitelistWithdraw: _whitelistWithdraw
        }));
        poolIdForLpAddress[_lpToken] = poolInfo.length - 1;
    }

    /// @notice Update the given pool's Fhm allocation point and deposit fee. Can only be called by the owner.
    function set(uint _pid, uint _allocPoint, uint16 _depositFeeBP, bool _withUpdate) public onlyOwner {
        require(_depositFeeBP <= 10000, "set: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
    }

    /// @notice Set the migrator contract. Can only be called by the owner.
    function setMigrator(IMigratorChef _migrator) public onlyOwner {
        migrator = _migrator;
    }

    /// @notice Migrate lp token to another lp contract. Can be called by anyone. We trust that migrator contract is good.
    function migrate(uint256 _pid) public {
        require(address(migrator) != address(0), "migrate: no migrator");
        PoolInfo storage pool = poolInfo[_pid];
        IERC20 lpToken = pool.lpToken;
        uint256 bal = lpToken.balanceOf(address(this));
        lpToken.safeApprove(address(migrator), 0);
        lpToken.safeApprove(address(migrator), bal);
        IERC20 newLpToken = migrator.migrate(lpToken);
        require(bal == newLpToken.balanceOf(address(this)), "migrate: bad");
        pool.lpToken = newLpToken;
    }

    /// @notice Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint _from, uint _to) public pure returns (uint) {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    /// @notice View function to see pending FHMs on frontend.
    function pendingFhm(uint _pid, address _user) external view returns (uint) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint accFhmPerShare = pool.accFhmPerShare;
        uint lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint fhmReward = multiplier.mul(fhmPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accFhmPerShare = accFhmPerShare.add(fhmReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accFhmPerShare).div(1e12).sub(user.rewardDebt).div(1e9 /* FHM has 9 decimals */);
    }

    /// @notice Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint length = poolInfo.length;
        for (uint pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    /// @notice Update reward variables for all pools. Be careful of gas spending!
    /// @param pids Pool IDs of all to be updated. Make sure to update all active pools.
    function massUpdatePools(uint256[] calldata pids) external {
        uint256 len = pids.length;
        for (uint256 i = 0; i < len; ++i) {
            updatePool(pids[i]);
        }
    }

    /// @notice Update reward variables of the given pool to be up-to-date.
    function updatePool(uint _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint fhmReward = multiplier.mul(fhmPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        //Mint Fhm rewards.
        ITreasury(treasuryAddress).mintRewards(feeAddress, fhmReward.div(12).div(1e9 /* FHM has 9 decimals */));
        ITreasury(treasuryAddress).mintRewards(address(this), fhmReward.div(1e9 /* FHM has 9 decimals */));
        pool.accFhmPerShare = pool.accFhmPerShare.add(fhmReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    /// @notice Deposit LP tokens to MasterChef for FHM allocation.
    function deposit(uint _pid, uint _amount, address _claimable) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_claimable];

        updatePool(_pid);
        if (user.amount > 0) {
            uint pending = user.amount.mul(pool.accFhmPerShare).div(1e12).sub(user.rewardDebt).div(1e9 /* FHM has 9 decimals */);
            if (pending > 0) {
                safeFhmTransfer(_claimable, pending);
            }
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            if (pool.depositFeeBP > 0) {
                uint depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                pool.lpToken.safeTransfer(feeAddress, depositFee);
                user.amount = user.amount.add(_amount).sub(depositFee);
            } else {
                user.amount = user.amount.add(_amount);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accFhmPerShare).div(1e12);
        if (pool.whitelistWithdraw && hasRole(WHITELIST_WITHDRAW_ROLE, msg.sender)) {
            user.whitelistWithdraw = true;
        }
        emit Deposit(_claimable, _pid, _amount);
    }

    /// @notice Withdraw LP tokens from MasterChef.
    function withdraw(uint _pid, uint _amount, address _claimable) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_claimable];
        if (pool.whitelistWithdraw && user.whitelistWithdraw) {
            require(hasRole(WHITELIST_WITHDRAW_ROLE, msg.sender), "WHITELIST_WITHDRAW_ROLE_MISSING");
        }
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint pending = user.amount.mul(pool.accFhmPerShare).div(1e12).sub(user.rewardDebt).div(1e9 /* FHM has 9 decimals */);
        if (pending > 0) {
            safeFhmTransfer(_claimable, pending);
        }
        if (_amount > 0) {
            if (user.amount > _amount) {
                user.amount = user.amount.sub(_amount);
            } else {
                user.amount = 0;
                user.whitelistWithdraw = false;
            }
            if (pool.whitelistWithdraw && user.whitelistWithdraw) {
                pool.lpToken.safeTransfer(address(msg.sender), _amount);
            } else {
                pool.lpToken.safeTransfer(_claimable, _amount);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accFhmPerShare).div(1e12);
        emit Withdraw(_claimable, _pid, _amount);
    }

    /// @notice Claim fhm rewards
    function harvest(uint256 _pid, address _to) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        updatePool(_pid);
        // this would  be the amount if the user joined right from the start of the farm
        uint256 accumulatedFhm = user.amount.mul(pool.accFhmPerShare).div(1e12);
        // subtracting the rewards the user is not eligible for
        uint256 eligibleFhm = accumulatedFhm.sub(user.rewardDebt).div(1e9 /* FHM has 9 decimals */);

        // we set the new rewardDebt to the current accumulated amount of rewards for his amount of LP token
        user.rewardDebt = accumulatedFhm;

        if (eligibleFhm > 0) {
            safeFhmTransfer(_to, eligibleFhm);
        }

        emit Harvest(msg.sender, _pid, eligibleFhm);
    }

    /// @notice Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdrawContract(uint _pid, address _user) public onlyOwner nonReentrant {
        require(_user.isContract(), "emergencyWithdrawContract: not contract");
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(_user, _pid, amount);
    }

    /// @notice Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        if (pool.whitelistWithdraw && user.whitelistWithdraw) {
            require(hasRole(WHITELIST_WITHDRAW_ROLE, msg.sender), "WHITELIST_WITHDRAW_ROLE_MISSING");
        }
        uint amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    /// @notice Safe FHM transfer function, just in case if rounding error causes pool to not have enough FHMs.
    function safeFhmTransfer(address _to, uint _amount) internal {
        uint fhmBal = fhm.balanceOf(address(this));
        bool transferSuccess = false;
        if (_amount > fhmBal) {
            transferSuccess = fhm.transfer(_to, fhmBal);
        } else {
            transferSuccess = fhm.transfer(_to, _amount);
        }
        require(transferSuccess, "safeFHMTransfer: transfer failed");
    }

    /// @notice Update treasury address by the owner.
    function treasury(address _treasuryAddress) public onlyOwner {
        treasuryAddress = _treasuryAddress;
        emit SetTreasuryAddress(treasuryAddress, _treasuryAddress);
    }

    function setFeeAddress(address _feeAddress) public onlyOwner {
        feeAddress = _feeAddress;
        emit SetFeeAddress(msg.sender, _feeAddress);
    }

    /// @notice Pancake has to add hidden dummy pools inorder to alter the emission, here we make it simple and transparent to all.
    function updateEmissionRate(uint _fhmPerBlock) public onlyOwner {
        massUpdatePools();
        fhmPerBlock = _fhmPerBlock;
        emit UpdateEmissionRate(msg.sender, _fhmPerBlock);
    }

    /// @notice grants WhitelistWithdraw role to given _account
    /// @param _account WhitelistWithdraw contract
    function grantRoleWhitelistWithdraw(address _account) external {
        grantRole(WHITELIST_WITHDRAW_ROLE, _account);
    }

    /// @notice revoke WhitelistWithdraw role to given _account
    /// @param _account WhitelistWithdraw contract
    function revokeRoleWhitelistWithdraw(address _account) external {
        revokeRole(WHITELIST_WITHDRAW_ROLE, _account);
    }

}
