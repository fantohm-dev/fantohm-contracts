// SPDX-License-Identifier: MIT

pragma solidity 0.7.5;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

interface IStaking {

    function stake(uint _amount, address _recipient) external returns (bool);

    function claim(address _recipient) external;

    function rebase() external;

    function epoch() external view returns (uint,uint,uint,uint);

    function warmupPeriod() external view returns (uint);
}

interface IsFHM {
    function rebase(uint256 ohmProfit_, uint epoch_) external returns (uint256);

    function circulatingSupply() external view returns (uint256);

    function balanceOf(address who) external view returns (uint256);

    function gonsForBalance(uint amount) external view returns (uint);

    function balanceForGons(uint gons) external view returns (uint);

    function index() external view returns (uint);
}

interface IStakingWarmupExecutor {
    function stake(uint _amount, address _recipient) external returns (bool);

    function claim(address _recipient) external;
}

/// @notice manages ability to call claim() and stake() and not reset warmup period each epoch+1
/// @dev each epoch % warmupPeriod one executor is doing claim and stake
contract StakingWarmupManager is Ownable {

    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public immutable FHM;
    address public immutable staking;

    address[] public executors;
    uint public currentEpochNumber;

    constructor(address _FHM, address _staking) {
        require(_FHM != address(0));
        FHM = _FHM;
        require(_staking != address(0));
        staking = _staking;
    }

    function checkBefore(uint _amount, address _recipient) private view {
        require(_recipient != address(0));
        require(_amount != 0);

        uint period = IStaking(staking).warmupPeriod();
        uint realLength = executorsLength();
        if (period == 0) require(realLength == 1, "Not enough executors to handle warmup periods");
        else require(realLength >= period, "Not enough executors to handle warmup periods");
    }

    /// @notice handles stake to be able to not reset expiry each time stakes in epoch+1
    /// @param _amount native tokena amount
    /// @param _recipient originating recipient
    function stake(uint _amount, address _recipient) external returns (bool) {
        checkBefore(_amount, _recipient);

        // tick rebase if can do it
        IStaking(staking).rebase();

        uint epochNumber = getEpochNumber();
        // switch current epoch executor
        if (currentEpochNumber < epochNumber) {
            currentEpochNumber = epochNumber;

            // claim previous warmups
            claim(_recipient);
        }

        // find executor in charge
        uint period = IStaking(staking).warmupPeriod();
        uint executorIndex = 0;
        if (period > 0) executorIndex = epochNumber % period;
        address executorAddress = executorGet(executorIndex);
        require(executorAddress != address(0), "No executor for given index");

        // transfer native tokens from originating _recipient to executor
        IERC20(FHM).safeTransferFrom(msg.sender, executorAddress, _amount);

        // stake in executor
        return IStakingWarmupExecutor(executorAddress).stake(_amount, _recipient);
    }

    /// @notice claim for _recipient on all warmup executors
    /// @param _recipient originating recipient
    function claim(address _recipient) public {
        checkBefore(1, _recipient);

        for (uint i = 0; i < executors.length; i++) {
            if (executors[i] != address(0)) {
                IStakingWarmupExecutor(executors[i]).claim(_recipient);
            }
        }
    }

    function getEpochNumber() public view returns (uint _epoch) {
        (,_epoch,,) = IStaking(staking).epoch();
    }

    /// @notice add new staking warmup executor
    function addExecutor(address _executor) external onlyOwner {
        require(_executor != address(0));
        executors.push(_executor);
    }

    /// @notice remove staking warmup executor
    function removeExecutor(uint _index) external onlyOwner {
        executors[_index] = address(0);
    }

    function executorsLength() private view returns (uint) {
        uint length = 0;
        for (uint i = 0; i < executors.length; i++) {
            if (executors[i] != address(0)) length++;
        }
        return length;
    }

    function executorGet(uint _index) private view returns (address) {
        uint index = 0;
        for (uint i = 0; i < executors.length; i++) {
            if (executors[i] != address(0) && index == _index) return executors[i];
            else index++;
        }
        return address(0);
    }

}
