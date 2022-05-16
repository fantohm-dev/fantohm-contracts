// SPDX-License-Identifier: MIT

pragma solidity 0.7.5;
pragma abicoder v2;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';

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


interface IAsset {
    // solhint-disable-previous-line no-empty-blocks
}

interface IVault {

    /**
     * @dev Called by users to join a Pool, which transfers tokens from `sender` into the Pool's balance. This will
     * trigger custom Pool behavior, which will typically grant something in return to `recipient` - often tokenized
     * Pool shares.
     *
     * If the caller is not `sender`, it must be an authorized relayer for them.
     *
     * The `assets` and `maxAmountsIn` arrays must have the same length, and each entry indicates the maximum amount
     * to send for each asset. The amounts to send are decided by the Pool and not the Vault: it just enforces
     * these maximums.
     *
     * If joining a Pool that holds WETH, it is possible to send ETH directly: the Vault will do the wrapping. To enable
     * this mechanism, the IAsset sentinel value (the zero address) must be passed in the `assets` array instead of the
     * WETH address. Note that it is not possible to combine ETH and WETH in the same join. Any excess ETH will be sent
     * back to the caller (not the sender, which is important for relayers).
     *
     * `assets` must have the same length and order as the array returned by `getPoolTokens`. This prevents issues when
     * interacting with Pools that register and deregister tokens frequently. If sending ETH however, the array must be
     * sorted *before* replacing the WETH address with the ETH sentinel value (the zero address), which means the final
     * `assets` array might not be sorted. Pools with no registered tokens cannot be joined.
     *
     * If `fromInternalBalance` is true, the caller's Internal Balance will be preferred: ERC20 transfers will only
     * be made for the difference between the requested amount and Internal Balance (if any). Note that ETH cannot be
     * withdrawn from Internal Balance: attempting to do so will trigger a revert.
     *
     * This causes the Vault to call the `IBasePool.onJoinPool` hook on the Pool's contract, where Pools implement
     * their own custom logic. This typically requires additional information from the user (such as the expected number
     * of Pool shares). This can be encoded in the `userData` argument, which is ignored by the Vault and passed
     * directly to the Pool's contract, as is `recipient`.
     *
     * Emits a `PoolBalanceChanged` event.
     */
    function joinPool(
        bytes32 poolId,
        address sender,
        address recipient,
        JoinPoolRequest memory request
    ) external payable;

    struct JoinPoolRequest {
        IAsset[] assets;
        uint[] maxAmountsIn;
        bytes userData;
        bool fromInternalBalance;
    }

    /**
     * @dev Called by users to exit a Pool, which transfers tokens from the Pool's balance to `recipient`. This will
     * trigger custom Pool behavior, which will typically ask for something in return from `sender` - often tokenized
     * Pool shares. The amount of tokens that can be withdrawn is limited by the Pool's `cash` balance (see
     * `getPoolTokenInfo`).
     *
     * If the caller is not `sender`, it must be an authorized relayer for them.
     *
     * The `tokens` and `minAmountsOut` arrays must have the same length, and each entry in these indicates the minimum
     * token amount to receive for each token contract. The amounts to send are decided by the Pool and not the Vault:
     * it just enforces these minimums.
     *
     * If exiting a Pool that holds WETH, it is possible to receive ETH directly: the Vault will do the unwrapping. To
     * enable this mechanism, the IAsset sentinel value (the zero address) must be passed in the `assets` array instead
     * of the WETH address. Note that it is not possible to combine ETH and WETH in the same exit.
     *
     * `assets` must have the same length and order as the array returned by `getPoolTokens`. This prevents issues when
     * interacting with Pools that register and deregister tokens frequently. If receiving ETH however, the array must
     * be sorted *before* replacing the WETH address with the ETH sentinel value (the zero address), which means the
     * final `assets` array might not be sorted. Pools with no registered tokens cannot be exited.
     *
     * If `toInternalBalance` is true, the tokens will be deposited to `recipient`'s Internal Balance. Otherwise,
     * an ERC20 transfer will be performed. Note that ETH cannot be deposited to Internal Balance: attempting to
     * do so will trigger a revert.
     *
     * `minAmountsOut` is the minimum amount of tokens the user expects to get out of the Pool, for each token in the
     * `tokens` array. This array must match the Pool's registered tokens.
     *
     * This causes the Vault to call the `IBasePool.onExitPool` hook on the Pool's contract, where Pools implement
     * their own custom logic. This typically requires additional information from the user (such as the expected number
     * of Pool shares to return). This can be encoded in the `userData` argument, which is ignored by the Vault and
     * passed directly to the Pool's contract.
     *
     * Emits a `PoolBalanceChanged` event.
     */
    function exitPool(
        bytes32 poolId,
        address sender,
        address payable recipient,
        ExitPoolRequest memory request
    ) external;

    struct ExitPoolRequest {
        IAsset[] assets;
        uint[] minAmountsOut;
        bytes userData;
        bool toInternalBalance;
    }

    function getPoolTokens(bytes32 poolId) external view returns (
        IERC20[] calldata tokens,
        uint[] calldata balances,
        uint lastChangeBlock
    );

    // Swaps
    //
    // Users can swap tokens with Pools by calling the `swap` and `batchSwap` functions. To do this,
    // they need not trust Pool contracts in any way: all security checks are made by the Vault. They must however be
    // aware of the Pools' pricing algorithms in order to estimate the prices Pools will quote.
    //
    // The `swap` function executes a single swap, while `batchSwap` can perform multiple swaps in sequence.
    // In each individual swap, tokens of one kind are sent from the sender to the Pool (this is the 'token in'),
    // and tokens of another kind are sent from the Pool to the recipient in exchange (this is the 'token out').
    // More complex swaps, such as one token in to multiple tokens out can be achieved by batching together
    // individual swaps.
    //
    // There are two swap kinds:
    //  - 'given in' swaps, where the amount of tokens in (sent to the Pool) is known, and the Pool determines (via the
    // `onSwap` hook) the amount of tokens out (to send to the recipient).
    //  - 'given out' swaps, where the amount of tokens out (received from the Pool) is known, and the Pool determines
    // (via the `onSwap` hook) the amount of tokens in (to receive from the sender).
    //
    // Additionally, it is possible to chain swaps using a placeholder input amount, which the Vault replaces with
    // the calculated output of the previous swap. If the previous swap was 'given in', this will be the calculated
    // tokenOut amount. If the previous swap was 'given out', it will use the calculated tokenIn amount. These extended
    // swaps are known as 'multihop' swaps, since they 'hop' through a number of intermediate tokens before arriving at
    // the final intended token.
    //
    // In all cases, tokens are only transferred in and out of the Vault (or withdrawn from and deposited into Internal
    // Balance) after all individual swaps have been completed, and the net token balance change computed. This makes
    // certain swap patterns, such as multihops, or swaps that interact with the same token pair in multiple Pools, cost
    // much less gas than they would otherwise.
    //
    // It also means that under certain conditions it is possible to perform arbitrage by swapping with multiple
    // Pools in a way that results in net token movement out of the Vault (profit), with no tokens being sent in (only
    // updating the Pool's internal accounting).
    //
    // To protect users from front-running or the market changing rapidly, they supply a list of 'limits' for each token
    // involved in the swap, where either the maximum number of tokens to send (by passing a positive value) or the
    // minimum amount of tokens to receive (by passing a negative value) is specified.
    //
    // Additionally, a 'deadline' timestamp can also be provided, forcing the swap to fail if it occurs after
    // this point in time (e.g. if the transaction failed to be included in a block promptly).
    //
    // If interacting with Pools that hold WETH, it is possible to both send and receive ETH directly: the Vault will do
    // the wrapping and unwrapping. To enable this mechanism, the IAsset sentinel value (the zero address) must be
    // passed in the `assets` array instead of the WETH address. Note that it is possible to combine ETH and WETH in the
    // same swap. Any excess ETH will be sent back to the caller (not the sender, which is relevant for relayers).
    //
    // Finally, Internal Balance can be used when either sending or receiving tokens.

    /**
     * @dev Performs a swap with a single Pool.
     *
     * If the swap is 'given in' (the number of tokens to send to the Pool is known), it returns the amount of tokens
     * taken from the Pool, which must be greater than or equal to `limit`.
     *
     * If the swap is 'given out' (the number of tokens to take from the Pool is known), it returns the amount of tokens
     * sent to the Pool, which must be less than or equal to `limit`.
     *
     * Internal Balance usage and the recipient are determined by the `funds` struct.
     *
     * Emits a `Swap` event.
     */
    function swap(
        SingleSwap memory singleSwap,
        FundManagement memory funds,
        uint256 limit,
        uint256 deadline
    ) external payable returns (uint256);

    /**
     * @dev Data for a single swap executed by `swap`. `amount` is either `amountIn` or `amountOut` depending on
     * the `kind` value.
     *
     * `assetIn` and `assetOut` are either token addresses, or the IAsset sentinel value for ETH (the zero address).
     * Note that Pools never interact with ETH directly: it will be wrapped to or unwrapped from WETH by the Vault.
     *
     * The `userData` field is ignored by the Vault, but forwarded to the Pool in the `onSwap` hook, and may be
     * used to extend swap behavior.
     */
    struct SingleSwap {
        bytes32 poolId;
        SwapKind kind;
        IAsset assetIn;
        IAsset assetOut;
        uint256 amount;
        bytes userData;
    }

    /**
     * @dev All tokens in a swap are either sent from the `sender` account to the Vault, or from the Vault to the
     * `recipient` account.
     *
     * If the caller is not `sender`, it must be an authorized relayer for them.
     *
     * If `fromInternalBalance` is true, the `sender`'s Internal Balance will be preferred, performing an ERC20
     * transfer for the difference between the requested amount and the User's Internal Balance (if any). The `sender`
     * must have allowed the Vault to use their tokens via `IERC20.approve()`. This matches the behavior of
     * `joinPool`.
     *
     * If `toInternalBalance` is true, tokens will be deposited to `recipient`'s internal balance instead of
     * transferred. This matches the behavior of `exitPool`.
     *
     * Note that ETH cannot be deposited to or withdrawn from Internal Balance: attempting to do so will trigger a
     * revert.
     */
    struct FundManagement {
        address sender;
        bool fromInternalBalance;
        address payable recipient;
        bool toInternalBalance;
    }

    enum SwapKind {GIVEN_IN, GIVEN_OUT}
}

interface IStablePool {
    function getPoolId() external view returns (bytes32);
}

/// @notice Make your life balanced
/// @author pwntr0n
/// @dev v2 with fine grained ACLs
contract BalanceHelper is Ownable, AccessControl {

    using SafeMath for uint;
    using SafeERC20 for IERC20;

    /// @dev ACL role for EOA to whitelist call our methods
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    /// @dev ACL role for EOA to whitelist call our methods
    bytes32 public constant USDB_MANAGER_ROLE = keccak256("USDB_MANAGER_ROLE");

    uint internal constant max = type(uint).max;

    address public immutable DAI;
    address public immutable USDB;
    address public immutable USDC;
    address public immutable lpToken;
    ITreasury public immutable treasury;
    IVault public immutable balancerVault;

    /// @notice triggerRatio DAI / 1000 USDB will allow to rebalance
    uint public triggerRatio;

    constructor(address _DAI, address _USDB, address _USDC, address _lpToken, address _treasury, address _balancerVault) {
        require(_DAI != address(0));
        DAI = _DAI;
        require(_USDB != address(0));
        USDB = _USDB;
        require(_USDC != address(0));
        USDC = _USDC;
        require(_lpToken != address(0));
        lpToken = _lpToken;

        require(_treasury != address(0));
        treasury = ITreasury(_treasury);
        require(_balancerVault != address(0));
        balancerVault = IVault(_balancerVault);

        triggerRatio = 950;

        IERC20(_DAI).approve(_balancerVault, max);
        IERC20(_DAI).approve(_treasury, max);
        IERC20(_USDB).approve(_balancerVault, max);
        IERC20(_USDB).approve(_treasury, max);
        IERC20(_lpToken).approve(_balancerVault, max);
        IERC20(_lpToken).approve(_treasury, max);

        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(MANAGER_ROLE, msg.sender);
    }

    function setTriggerRatio(uint _triggerRatio) external onlyOwner {
        triggerRatio = _triggerRatio;
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

    /// @notice grants usdb manager role to given _account
    /// @param _account usdb manager contract
    function grantRoleUsdbManager(address _account) external {
        grantRole(USDB_MANAGER_ROLE, _account);
    }

    /// @notice revoke usdb manager role to given _account
    /// @param _account usdb manager contract
    function revokeRoleUsdbManager(address _account) external {
        revokeRole(USDB_MANAGER_ROLE, _account);
    }

    ///
    /// business logic
    ///

    /// @notice rebalance pool by removing usdb
    function rebalance_lpRemoveUsdb() external {
        require(hasRole(MANAGER_ROLE, msg.sender) || hasRole(USDB_MANAGER_ROLE, msg.sender), "MISSING_MANAGER_ROLE");

        (IERC20[] memory tokens, uint[] memory totalBalances) = doGetPoolTokens();
        require(address(tokens[0]) == USDB && address(tokens[1]) == DAI, "WRONG_TOKEN_ORDER");

        // usdb / dai should be greater than 1000/triggerRatio like there should be more usdb
        require(getPoolRatio(false) <= triggerRatio, "NOT_ENOUGH_RATIO");

        // usdb - dai
        uint toRemove = totalBalances[0].sub(totalBalances[1]);

        // manage LP token
        treasury.manage(lpToken, toRemove);

        // single sided remove usdb
        (uint usdbAmount,) = exitPool(toRemove, 0);

        // deposit into treasury without generating any profit
        uint fhmValuation = treasury.valueOf(USDB, usdbAmount);
        treasury.deposit(usdbAmount, USDB, fhmValuation);
    }

    /// @notice rebalance pool by removing dai
    function rebalance_lpRemoveDai() external {
        require(hasRole(MANAGER_ROLE, msg.sender), "MISSING_MANAGER_ROLE");

        (IERC20[] memory tokens, uint[] memory totalBalances) = doGetPoolTokens();
        require(address(tokens[0]) == USDB && address(tokens[1]) == DAI, "WRONG_TOKEN_ORDER");

        // dai / usdb should be greater than 1000/triggerRatio like there should be more dai
        require(getPoolRatio(true) <= triggerRatio, "NOT_ENOUGH_RATIO");

        // dai - usdb
        uint toRemove = totalBalances[1].sub(totalBalances[0]);

        // manage LP token
        treasury.manage(lpToken, toRemove);

        // single sided remove usdb
        (,uint daiAmount) = exitPool(toRemove, 1);

        // deposit into treasury without generating any profit
        uint fhmValuation = treasury.valueOf(DAI, daiAmount);
        treasury.deposit(daiAmount, DAI, fhmValuation);
    }

    /// @notice rebalance by adding usdb
    function rebalance_lpAddUsdb() external {
        require(hasRole(MANAGER_ROLE, msg.sender) || hasRole(USDB_MANAGER_ROLE, msg.sender), "MISSING_MANAGER_ROLE");

        (IERC20[] memory tokens, uint[] memory totalBalances) = doGetPoolTokens();
        require(address(tokens[0]) == USDB && address(tokens[1]) == DAI, "WRONG_TOKEN_ORDER");

        // dai / usdb should be greater than 1000/triggerRatio like there should be more dai
        require(getPoolRatio(true) <= triggerRatio, "NOT_ENOUGH_RATIO");

        // dai - usdb
        uint toAdd = totalBalances[1].sub(totalBalances[0]);

        // manage LP token
        treasury.manage(USDB, toAdd);

        uint lpTokenAmount = joinPool(toAdd, 0);
        // deposit into treasury without generating any profit
        uint fhmValuation = treasury.valueOf(lpToken, lpTokenAmount);
        treasury.deposit(lpTokenAmount, lpToken, fhmValuation);
    }

    /// @notice rebalance by adding dai
    function rebalance_lpAddDai() external {
        require(hasRole(MANAGER_ROLE, msg.sender), "MISSING_MANAGER_ROLE");

        (IERC20[] memory tokens, uint[] memory totalBalances) = doGetPoolTokens();
        require(address(tokens[0]) == USDB && address(tokens[1]) == DAI, "WRONG_TOKEN_ORDER");

        // usdb / dai should be greater than 1000/triggerRatio like there should be more usdb
        require(getPoolRatio(false) <= triggerRatio, "NOT_ENOUGH_RATIO");

        // usdb - dai
        uint toAdd = totalBalances[0].sub(totalBalances[1]);

        // manage LP token
        treasury.manage(DAI, toAdd);

        uint lpTokenAmount = joinPool(0, toAdd);
        // deposit into treasury without generating any profit
        uint fhmValuation = treasury.valueOf(lpToken, lpTokenAmount);
        treasury.deposit(lpTokenAmount, lpToken, fhmValuation);
    }

    /// @notice rebalance by sell dai into pool
    function rebalance_sellDai() external {
        require(hasRole(MANAGER_ROLE, msg.sender), "MISSING_MANAGER_ROLE");

        (IERC20[] memory tokens,uint[] memory totalBalances) = doGetPoolTokens();
        require(address(tokens[0]) == USDB && address(tokens[1]) == DAI, "WRONG_TOKEN_ORDER");

        // usdb / dai should be greater than 1 there should be more usdb
        require(totalBalances[0] >= totalBalances[1], "NOT_ENOUGH_RATIO");

        uint toSell = totalBalances[0].sub(totalBalances[1]).div(2);
        // manage LP token
        treasury.manage(DAI, toSell);

        uint usdbOut = swapAmountIn(DAI, USDB, toSell, IStablePool(lpToken).getPoolId());
        // deposit into treasury without generating any profit
        uint fhmValuation = treasury.valueOf(USDB, usdbOut);
        treasury.deposit(usdbOut, USDB, fhmValuation);
    }

    /// @notice rebalance by sell usdb into pool
    function rebalance_sellUsdb() external {
        require(hasRole(MANAGER_ROLE, msg.sender), "MISSING_MANAGER_ROLE");

        (IERC20[] memory tokens,uint[] memory totalBalances) = doGetPoolTokens();
        require(address(tokens[0]) == USDB && address(tokens[1]) == DAI, "WRONG_TOKEN_ORDER");

        // dai / usdb should be greater than 1 there should be more usdb
        require(totalBalances[1] >= totalBalances[0], "NOT_ENOUGH_RATIO");

        uint toSell = totalBalances[1].sub(totalBalances[0]).div(2);
        // manage LP token
        treasury.manage(USDB, toSell);

        uint daiOut = swapAmountIn(USDB, DAI, toSell, IStablePool(lpToken).getPoolId());
        // deposit into treasury without generating any profit
        uint fhmValuation = treasury.valueOf(DAI, daiOut);
        treasury.deposit(daiOut, DAI, fhmValuation);
    }

    ///
    /// balancer logic
    ///

    /**
    * @dev This helper function is a fast and cheap way to convert between IERC20[] and IAsset[] types
     */
    function _convertERC20sToAssets(IERC20[] memory tokens) internal pure returns (IAsset[] memory assets) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            assets := tokens
        }
    }

    function getPoolRatio(bool usdbFirst) public view returns (uint) {
        (IERC20[] memory tokens, uint[] memory totalBalances) = doGetPoolTokens();
        require(address(tokens[0]) == USDB && address(tokens[1]) == DAI, "WRONG_TOKEN_ORDER");

        if (usdbFirst) return totalBalances[0].mul(1000).div(totalBalances[1]);
        return totalBalances[1].mul(1000).div(totalBalances[0]);
    }

    function getPoolTokens() public view returns (IERC20[] memory _tokens, uint[] memory _totalBalances) {
        (IERC20[] memory tokens, uint[] memory totalBalances) = doGetPoolTokens();

        _tokens = tokens;
        _totalBalances = new uint[](2);
        _totalBalances[0] = totalBalances[0].div(1e18);
        _totalBalances[1] = totalBalances[1].div(1e18);
    }

    function doGetPoolTokens() private view returns (IERC20[] memory tokens, uint[] memory totalBalances) {
        (tokens, totalBalances,) = balancerVault.getPoolTokens(IStablePool(lpToken).getPoolId());
    }

    function joinPool(uint _usdbAmount, uint _daiAmount) private returns (uint _lpTokenAmount) {
        // https://dev.balancer.fi/resources/joins-and-exits/pool-joins
        // https://github.com/balancer-labs/balancer-v2-monorepo/blob/master/pkg/balancer-js/src/pool-stable/encoder.ts
        (IERC20[] memory tokens,) = doGetPoolTokens();

        uint[] memory rawAmounts = new uint[](2);
        rawAmounts[0] = _usdbAmount;
        rawAmounts[1] = _daiAmount;

        bytes memory userDataEncoded = abi.encode(1 /* EXACT_TOKENS_IN_FOR_BPT_OUT */, rawAmounts, 0);

        IVault.JoinPoolRequest memory request = IVault.JoinPoolRequest({
        assets : _convertERC20sToAssets(tokens),
        maxAmountsIn : rawAmounts,
        userData : userDataEncoded,
        fromInternalBalance : false
        });

        uint tokensBefore = IERC20(lpToken).balanceOf(address(this));
        balancerVault.joinPool(IStablePool(lpToken).getPoolId(), address(this), address(this), request);
        uint tokensAfter = IERC20(lpToken).balanceOf(address(this));

        _lpTokenAmount = tokensAfter.sub(tokensBefore);
    }

    function exitPool(uint _lpTokensAmount, uint _tokenIndex) private returns (uint _usdbAmount, uint _principleAmount) {
        (IERC20[] memory tokens,) = doGetPoolTokens();

        // https://dev.balancer.fi/resources/joins-and-exits/pool-exits
        uint[] memory minAmountsOut = new uint[](2);

        bytes memory userDataEncoded = abi.encode(0 /* EXACT_BPT_IN_FOR_ONE_TOKEN_OUT */, _lpTokensAmount, _tokenIndex);

        IVault.ExitPoolRequest memory request = IVault.ExitPoolRequest({
        assets : _convertERC20sToAssets(tokens),
        minAmountsOut : minAmountsOut,
        userData : userDataEncoded,
        toInternalBalance : false
        });

        uint usdbBefore = IERC20(USDB).balanceOf(address(this));
        uint principleBefore = IERC20(DAI).balanceOf(address(this));
        balancerVault.exitPool(IStablePool(lpToken).getPoolId(), address(this), payable(address(this)), request);
        uint usdbAfter = IERC20(USDB).balanceOf(address(this));
        uint principleAfter = IERC20(DAI).balanceOf(address(this));

        _usdbAmount = usdbAfter.sub(usdbBefore);
        _principleAmount = principleAfter.sub(principleBefore);
    }

    function swapAmountIn(
        address _tokenIn,
        address _tokenOut,
        uint _amountIn,
        bytes32 _poolId
    ) internal returns (uint _amountOut) {
        IVault.SingleSwap memory singleSwap = IVault.SingleSwap(
            _poolId, IVault.SwapKind.GIVEN_IN, IAsset(_tokenIn), IAsset(_tokenOut), _amountIn, ""
        );

        IVault.FundManagement memory funds = IVault.FundManagement(
            address(this), false, payable(address(this)), false
        );

        return balancerVault.swap(singleSwap, funds, 0, block.timestamp);
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

    /// @dev Required for the Vault to receive unwrapped ETH.
    receive() external payable {}

}