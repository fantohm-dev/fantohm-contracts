// SPDX-License-Identifier: MIT

pragma solidity 0.7.5;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import "@openzeppelin/contracts/math/SafeMath.sol";

import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router01.sol";

interface IwsFHM is IERC20 {
    function unwrap(uint _amount) external returns (uint);
}

interface IStaking {
    function unstake(uint _amount, bool _trigger) external;
}

interface IBurnable is IERC20 {
    function burn(uint amount) external;
}

interface IUsdbMinter {
    function getMarketPrice() external view returns (uint);

    function mintFromFHM(uint _stableCoinAmount, uint _minimalTokenPrice) external;
}

interface ITreasury {
    /** @notice allow approved address to withdraw assets
        @param _token address
        @param _amount uint
     */
    function manage(address _token, uint _amount) external;

    /** @notice returns OHM valuation of asset
        @param _token address
        @param _amount uint
        @return value_ uint
     */
    function valueOf(address _token, uint _amount) external view returns (uint value_);

    /**
        @notice allow approved address to deposit an asset for OHM
        @param _amount uint
        @param _token address
        @param _profit uint
        @return send_ uint
     */
    function deposit(uint _amount, address _token, uint _profit) external returns (uint send_);
}

interface IUniswapV2ERC20 {
    function totalSupply() external view returns (uint);
}

interface IUniswapV2Pair is IUniswapV2ERC20 {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    function token0() external view returns (address);

    function token1() external view returns (address);
}

/// @notice Some man just want to watch the world burn!
/// @author pwntr0n
contract BurnHelperV3 is Ownable, AccessControl {

    using SafeMath for uint;
    using SafeERC20 for IERC20;

    /// @dev ACL role for EOA to whitelist call our methods
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    uint internal constant max = type(uint).max;

    IERC20 public immutable DAI;
    IBurnable public immutable FHM;
    IERC20 public immutable sFHM;
    IwsFHM public immutable wsFHM;
    IERC20 public immutable USDB;
    IStaking public immutable staking;
    address public immutable uniswapV2Router;
    address public immutable lp;
    IUsdbMinter public immutable usdbMinter;
    ITreasury public immutable treasury;

    struct SoldBonds {
        uint timestampFrom;
        uint timestampTo;
        uint payoutInUsd;
    }

    bool public useCircuitBreaker;
    SoldBonds[] public buybacksInHour;
    SoldBonds[] public usdbMintsInHour;

    uint buybacksLimitUsd;
    uint usdbMintsLimitUsd;

    ///
    /// events
    ///

    event SwapAndLiquifyFailed(bytes _failErr);

    ///
    /// administration
    ///

    constructor(address _DAI, address _FHM, address _sFHM, address _wsFHM, address _USDB, address _staking, address _uniswapV2Router, address _lp, address _usdbMinter, address _treasury) {
        require(_DAI != address(0));
        DAI = IERC20(_DAI);
        require(_FHM != address(0));
        FHM = IBurnable(_FHM);
        require(_sFHM != address(0));
        sFHM = IERC20(_sFHM);
        require(_wsFHM != address(0));
        wsFHM = IwsFHM(_wsFHM);
        require(_USDB != address(0));
        USDB = IERC20(_USDB);
        require(_staking != address(0));
        staking = IStaking(_staking);
        require(_uniswapV2Router != address(0));
        uniswapV2Router = _uniswapV2Router;
        require(_lp != address(0));
        lp = _lp;
        require(_usdbMinter != address(0));
        usdbMinter = IUsdbMinter(_usdbMinter);
        require(_treasury != address(0));
        treasury = ITreasury(_treasury);

        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(MANAGER_ROLE, msg.sender);

        IERC20(_DAI).approve(_uniswapV2Router, max);
        IERC20(_sFHM).approve(_staking, max);
        IERC20(_FHM).approve(_usdbMinter, max);
        IERC20(_USDB).approve(_treasury, max);
    }

    /// @notice grants manager role to given _account
    /// @param _account manager contract
    function grantRoleManager(address _account) external {
        grantRole(MANAGER_ROLE, _account);
    }

    /// @notice revoke manager role to given _account
    /// @param _account manager contract
    function revokeRoleManager(address _account) external {
        revokeRole(MANAGER_ROLE, _account);
    }

    ///
    /// burns
    ///

    /// @notice convenient method how to burn wrapped token from gnosis
    function burnAllWrappedTokens(bool _rawBurn) external {
        uint balance = wsFHM.balanceOf(msg.sender);
        wsFHM.transferFrom(msg.sender, address(this), balance);

        wsFHM.unwrap(balance);
        staking.unstake(sFHM.balanceOf(address(this)), true);

        if (_rawBurn) {
            burn();
        } else {
            burnIntoUsdb();
        }
    }

    /// @notice convenient method how to burn staked token from gnosis
    function burnAllStakedTokens(bool _rawBurn) external {
        uint balance = sFHM.balanceOf(msg.sender);
        sFHM.transferFrom(msg.sender, address(this), balance);

        IStaking(staking).unstake(balance, true);

        if (_rawBurn) {
            burn();
        } else {
            burnIntoUsdb();
        }
    }

    /// @notice convenient method how to burn native token from gnosis
    function burnAllNativeTokens(bool _rawBurn) external {
        if (_rawBurn) {
            burn();
        } else {
            burnIntoUsdb();
        }
    }

    function burn() internal {
        uint marketPrice = usdbMinter.getMarketPrice();
        uint fhmAmount = FHM.balanceOf(address(this));
        uint usdbAmount = fhmAmount.mul(marketPrice).div(1e2);

        require(!buybacksCircuitBreakerActivated(usdbAmount), "CIRCUIT_BREAKER_ACTIVE");
        if (useCircuitBreaker) updateSoldBonds(buybacksInHour, usdbAmount);

        FHM.burn(fhmAmount);
    }

    function burnIntoUsdb() internal {
        uint marketPrice = usdbMinter.getMarketPrice();
        uint fhmAmount = FHM.balanceOf(address(this));
        uint usdbAmount = fhmAmount.mul(marketPrice).div(1e2);

        require(!usdbMintsCircuitBreakerActivated(usdbAmount), "CIRCUIT_BREAKER_ACTIVE");
        if (useCircuitBreaker) updateSoldBonds(usdbMintsInHour, usdbAmount);

        usdbMinter.mintFromFHM(usdbAmount, marketPrice);

        // deposit into treasury without generating any profit
        uint fhmValuation = treasury.valueOf(address(USDB), usdbAmount);
        treasury.deposit(usdbAmount, address(USDB), fhmValuation);
    }

    ///
    /// buybacks
    ///


    function buybackAndBurn(uint _daiAmountWithoutDecimals, uint _slipPageWith1Decimal, bool _rawBurn) external {
        require(hasRole(MANAGER_ROLE, msg.sender), "MISSING_MANAGER_ROLE");

        // manage LP token
        treasury.manage(address(DAI), _daiAmountWithoutDecimals * 1e18);

        if (_slipPageWith1Decimal == 0) {
            // default slip page same as in spookyswap
            _slipPageWith1Decimal = 8;
        }

        uint daiAmount = DAI.balanceOf(address(this));

        (uint reserveA, uint reserveB) = getReserves(lp, address(DAI), address(FHM));
        uint fhmAmount = getAmountOut(daiAmount, reserveA, reserveB);

        swapTokensForTokens(daiAmount, fhmAmount.mul(uint(1000).sub(_slipPageWith1Decimal)).div(1000));

        if (_rawBurn) {
            burn();
        } else {
            burnIntoUsdb();
        }
    }


    function updateSoldBonds(SoldBonds[] storage soldBondsInHour, uint _payout) internal {
        uint length = soldBondsInHour.length;
        if (length == 0) {
            soldBondsInHour.push(SoldBonds({
            timestampFrom : block.timestamp,
            timestampTo : block.timestamp + 1 hours,
            payoutInUsd : _payout
            }));
            return;
        }

        SoldBonds storage soldBonds = soldBondsInHour[length - 1];
        // update in existing interval
        if (soldBonds.timestampFrom < block.timestamp && soldBonds.timestampTo >= block.timestamp) {
            soldBonds.payoutInUsd = soldBonds.payoutInUsd.add(_payout);
        } else {
            // create next interval if its continuous
            uint nextTo = soldBonds.timestampTo + 1 hours;
            if (block.timestamp <= nextTo) {
                soldBondsInHour.push(SoldBonds({
                timestampFrom : soldBonds.timestampTo,
                timestampTo : nextTo,
                payoutInUsd : _payout
                }));
            } else {
                soldBondsInHour.push(SoldBonds({
                timestampFrom : block.timestamp,
                timestampTo : block.timestamp + 1 hours,
                payoutInUsd : _payout
                }));
            }
        }
    }

    function buybacksCurrentPayout() public view returns (uint _amount) {
        return soldBondsCurrentPayout(buybacksInHour);
    }

    function usdbMintsCurrentPayout() public view returns (uint _amount) {
        return soldBondsCurrentPayout(usdbMintsInHour);
    }

    function soldBondsCurrentPayout(SoldBonds[] storage soldBondsInHour) internal view returns (uint _amount) {
        if (soldBondsInHour.length == 0) return 0;

        uint _max = 0;
        if (soldBondsInHour.length >= 24) _max = soldBondsInHour.length - 24;

        uint to = block.timestamp;
        uint from = to - 24 hours;
        for (uint i = _max; i < soldBondsInHour.length; i++) {
            SoldBonds memory soldBonds = soldBondsInHour[i];
            if (soldBonds.timestampFrom >= from && soldBonds.timestampFrom <= to) {
                _amount = _amount.add(soldBonds.payoutInUsd);
            }
        }

        return _amount;
    }

    function buybacksCircuitBreakerActivated(uint _payout) public view returns (bool) {
        if (!useCircuitBreaker) return false;
        _payout = _payout.add(buybacksCurrentPayout());
        return _payout > buybacksLimitUsd;
    }

    function usdbMintsCircuitBreakerActivated(uint _payout) public view returns (bool) {
        if (!useCircuitBreaker) return false;
        _payout = _payout.add(usdbMintsCurrentPayout());
        return _payout > usdbMintsLimitUsd;
    }

    ///
    /// uniswap logic
    ///

    function swapTokensForTokens(uint _amountIn, uint _minAmountOut) private {
        address[] memory path = new address[](2);
        path[0] = address(DAI);
        path[1] = address(FHM);

        // make the swap
        try IUniswapV2Router01(uniswapV2Router).swapExactTokensForTokens(
            _amountIn,
            _minAmountOut,
            path,
            address(this),
            block.timestamp
        ) {
            // save the gas, not emit any event, its visible anyways
        } catch (bytes memory e) {
            emit SwapAndLiquifyFailed(e);
        }
    }

    // returns sorted token addresses, used to handle return values from pairs sorted in this order
    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, 'UniswapV2Library: IDENTICAL_ADDRESSES');
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'UniswapV2Library: ZERO_ADDRESS');
    }

    // fetches and sorts the reserves for a pair
    function getReserves(address _lp, address tokenA, address tokenB) internal view returns (uint reserveA, uint reserveB) {
        (address token0,) = sortTokens(tokenA, tokenB);
        (uint reserve0, uint reserve1,) = IUniswapV2Pair(_lp).getReserves();
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) internal pure returns (uint amountOut) {
        require(amountIn > 0, 'UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');
        uint amountInWithFee = amountIn.mul(997);
        uint numerator = amountInWithFee.mul(reserveOut);
        uint denominator = reserveIn.mul(1000).add(amountInWithFee);
        amountOut = numerator / denominator;
    }

    ///
    /// emergency logic
    ///

    /// @notice Been able to recover any token which is sent to contract by mistake
    /// @param token erc20 token
    function emergencyRecoverToken(address token) external virtual onlyOwner {
        uint amount = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    /// @notice Been able to recover any ftm/movr token sent to contract by mistake
    function emergencyRecoverEth() external virtual onlyOwner {
        uint amount = address(this).balance;
        payable(msg.sender).transfer(amount);
    }

}