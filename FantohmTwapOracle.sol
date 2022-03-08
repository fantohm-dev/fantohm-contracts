// SPDX-License-Identifier: MIT

pragma solidity 0.7.5;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import '@uniswap/lib/contracts/libraries/FixedPoint.sol';
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import '@uniswap/v2-periphery/contracts/libraries/UniswapV2OracleLibrary.sol';

/// @notice FantOHM DAO TWAP Oracle for on-chain price feed
/// @author pwntr0n
contract FantohmTwapOracle is Ownable, AccessControl {
    using FixedPoint for *;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant UPDATER_ROLE = keccak256("UPDATER_ROLE");

    struct Observation {
        bool whitelisted;
        uint price0CumulativeLast;
        uint price1CumulativeLast;
        uint blockTimestampLast;
    }

    mapping(address => Observation) oracle;

    constructor() {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(OPERATOR_ROLE, msg.sender);
        _setupRole(UPDATER_ROLE, msg.sender);
    }

    /* ///////////////////////////////////////////////////////////////
                               MANAGEMENT
   ////////////////////////////////////////////////////////////// */

    function addPair(address _pair) external {
        require(hasRole(OPERATOR_ROLE, _msgSender()), "MISSING_ROLE_OPERATOR");

        Observation storage twap = oracle[_pair];
        require(!twap.whitelisted, "Already whitelisted");

        twap.whitelisted = true;
    }

    function removePair(address _pair) external {
        require(hasRole(OPERATOR_ROLE, _msgSender()), "MISSING_ROLE_OPERATOR");

        Observation memory twap = oracle[_pair];
        require(twap.whitelisted, "Not whitelisted");

        delete oracle[_pair];
    }

    /// @notice grants operator role to given _account
    /// @param _account operator contract
    function grantRoleOperator(address _account) external {
        grantRole(OPERATOR_ROLE, _account);
    }

    /// @notice revoke operator role to given _account
    /// @param _account operator contract
    function revokeRoleOperator(address _account) external {
        revokeRole(OPERATOR_ROLE, _account);
    }


    /// @notice grants updater role to given _account
    /// @param _account updater contract
    function grantRoleUpdater(address _account) external {
        grantRole(UPDATER_ROLE, _account);
    }

    /// @notice revoke updater role to given _account
    /// @param _account updater contract
    function revokeRoleUpdater(address _account) external {
        revokeRole(UPDATER_ROLE, _account);
    }

    /* ///////////////////////////////////////////////////////////////
                           UPDATE
    ////////////////////////////////////////////////////////////// */

    /// @notice update TWAP anchor for give _pair
    /// @dev needs to be called in cron
    /// @param _pair LP
    function update(address _pair) external {
        require(hasRole(UPDATER_ROLE, _msgSender()), "MISSING_ROLE_UPDATER");

        Observation storage twap = oracle[_pair];
        require(twap.whitelisted, "NOT_WHITELISTED");

        (twap.price0CumulativeLast, twap.price1CumulativeLast,) = UniswapV2OracleLibrary.currentCumulativePrices(_pair);
        twap.blockTimestampLast = block.timestamp;
    }


    /* ///////////////////////////////////////////////////////////////
                        ORACLE
    ////////////////////////////////////////////////////////////// */


    /// @notice get most accurate _amountOut amount for _amountIn amount of _token tokens
    /// @param _pair liquidity pair
    /// @param _token token you want to know the price
    /// @param _amountIn amounts of token you want to know the price
    /// @return _amountOut resulting price
    function consult(address _pair, address _token, uint _amountIn) external view returns (uint _amountOut) {
        Observation memory twap = oracle[_pair];
        require(twap.whitelisted, "NOT_WHITELISTED");

        uint timeElapsed = block.timestamp - twap.blockTimestampLast;
        (uint price0Cumulative, uint price1Cumulative,) = UniswapV2OracleLibrary.currentCumulativePrices(_pair);

        if (_token == IUniswapV2Pair(_pair).token0()) {
            FixedPoint.uq112x112 memory price0Average = FixedPoint.uq112x112(uint224((price0Cumulative - twap.price0CumulativeLast) / timeElapsed));
            _amountOut = price0Average.mul(_amountIn).decode144();
        } else {
            require(_token == IUniswapV2Pair(_pair).token1(), "INVALID_TOKEN");
            FixedPoint.uq112x112 memory price1Average = FixedPoint.uq112x112(uint224((price1Cumulative - twap.price1CumulativeLast) / timeElapsed));
            _amountOut = price1Average.mul(_amountIn).decode144();
        }
    }
}
