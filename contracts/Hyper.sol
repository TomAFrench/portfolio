// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

//////////////////////////////////////////////////////////////////////////////////////////////////////
//                                                           __----~~~~~~~~~~~------___             //
//       It's a dragon!                           .  .   ~~//====......          __--~ ~~           //
//                                -.            \_|//     |||\\  ~~~~~~::::... /~                   //
//                             ___-==_       _-~o~  \/    |||  \\            _/~~-                  //
//                     __---~~~.==~||\=_    -_--~/_-~|-   |\\   \\        _/~                       //
//                 _-~~     .=~    |  \\-_    '-~7  /-   /  ||    \      /                          //
//               .~       .~       |   \\ -_    /  /-   /   ||      \   /                           //
//              /  ____  /         |     \\ ~-_/  /|- _/   .||       \ /                            //
//              |~~    ~~|--~~~~--_ \     ~==-/   | \~--===~~        .\                             //
//                       '         ~-|      /|    |-~\~~       __--~~                               //
//                                   |-~~-_/ |    |   ~\_   _-~            /\                       //
//                                        /  \     \__   \/~                \__                     //
//                                    _--~ _/ | .-~~____--~-/                  ~~==.                //
//                                   ((->/~   '.|||' -_|    ~~-/ ,              . _||               //
//                                              -_     ~\      ~~---l__i__i__i--~~_/                //
//                                              _-~-__   ~)  \--______________--~~                  //
//                                            //.-~~~-~_--~- |-------~~~~~~~~                       //
//                                                   //.-~~~--\                                     //
//////////////////////////////////////////////////////////////////////////////////////////////////////

import "./OS.sol";
import "./CPU.sol" as CPU;
import "./Clock.sol";
import "./Assembly.sol" as asm;
import "./EnigmaTypes.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/IHyper.sol";
import "./interfaces/IERC20.sol";
import "./libraries/Price.sol";

/**
 * @title   Enigma Virtual Machine.
 * @notice  Exposes an external api and an alternative multi-operation api that uses compressed data inputs.
 * @dev     Implements low-level internal functions, re-entrancy guard and state.
 */
contract Hyper is IHyper {
    using {asm.toUint128, asm.toUint48, asm.toUint32, asm.toUint24, asm.toUint16} for uint;
    using FixedPointMathLib for int256;
    using FixedPointMathLib for uint256;
    using Price for Price.Expiring;

    // ===== Account ===== //
    AccountSystem public __account__;

    // ===== Constants ===== //
    string public constant VERSION = "beta-v0.0.1";
    /// @dev Canonical Wrapped Ether contract.
    address public immutable WETH;
    /// @dev Maximum price multiple. Equal to 5x price at 1bps tick sizes.
    int24 public constant MAX_TICK = 25556; // TODO: Fix
    /// @dev Distance between the location of prices on the price grid, so distance between price.
    int24 public constant TICK_SIZE = 256;
    /// @dev Minimum amount of decimals supported for ERC20 tokens.
    uint8 public constant MIN_DECIMALS = 6;
    /// @dev Maximum amount of decimals supported for ERC20 tokens.
    uint8 public constant MAX_DECIMALS = 18;
    /// @dev Amount of seconds of available time to swap past maturity of a pool.
    uint256 public constant BUFFER = 300;
    /// @dev Constant amount of 1 ether. All liquidity values have 18 decimals.
    uint256 public constant PRECISION = 1e18;
    /// @dev Constant amount of basis points. All percentage values are integers in basis points.
    uint256 public constant PERCENTAGE = 1e4;
    /// @dev Minimum pool fee. 0.01%.
    uint256 public constant MIN_POOL_FEE = 1;
    /// @dev Maximum pool fee. 10.00%.
    uint256 public constant MAX_POOL_FEE = 1e3;
    /// @dev Amount of seconds that an epoch lasts.
    uint256 public constant EPOCH_INTERVAL = 3600 seconds; // 1 hr
    /// @dev Used to compute the amount of liquidity to burn on creating a pool.
    uint256 public constant MIN_LIQUIDITY_FACTOR = 6;
    /// @dev Policy for the "wait" time in seconds between adding and removing liquidity.
    uint256 public constant JUST_IN_TIME_LIQUIDITY_POLICY = 4;

    // ===== State ===== //
    /// @dev Reentrancy guard initialized to state
    uint256 private locked = 1;
    /// @dev A value incremented by one on pair creation. Reduces calldata.
    uint256 public getPairNonce;
    /// @dev A value incremented by one on curve creation. Reduces calldata.
    uint32 public getPoolNonce;
    // todo: fix, lets say this is the current epoch for now.
    uint48 public currentEpoch = 1; 
    /// @dev Pool id -> Pair of a Pool.
    mapping(uint24 => Pair) public pairs;
    /// @dev Pool id -> Epoch Data Structure.
    mapping(uint64 => Epoch) public epochs;
    /// @dev Pool id -> HyperPool Data Structure.
    mapping(uint64 => HyperPool) public pools;
    /// @dev Base Token -> Quote Token -> Pair id
    mapping(address => mapping(address => uint24)) public getPairId;
    /// @dev User -> Position Id -> Liquidity Position.
    mapping(address => mapping(uint64 => HyperPosition)) public positions;
    /// @dev Amount of rewards globally tracked per epoch.
    mapping(uint64 => mapping(uint256 => uint256)) internal epochRewardGrowthGlobal;
    /// @dev Individual rewards of a position.
    mapping(uint64 => mapping(int24 => mapping(uint256 => uint256))) internal epochRewardGrowthOutside;

    // ===== Reentrancy ===== //

    /** @dev Used on every external function and external entrypoint. */
    modifier lock() {
        if (locked != 1) revert LockedError();

        locked = 2;
        _;
        locked = 1;
    }

    /** @dev Used on every external operation that touches tokens. */
    modifier interactions() {
        __account__.__wrapEther__(WETH); // Deposits msg.value ether, this contract receives WETH.
        _;
        __account__.prepare();
        __account__.settlement(__dangerousTransferFrom__, address(this));

        if (!__account__.settled) revert InvalidSettlement();
    }

    // ===== Constructor ===== //
    constructor(address weth) {
        WETH = weth;
        __account__.settled = true;
    }

    // ===== Getters ===== //

    /** @dev Fetches internally tracked amount of `token` owned by this contract. */
    function getReserve(address token) public view returns (uint) {
        return __account__.reserves[token];
    }

    /** @dev Fetches internally tracked amount of `token` owned by `owner`. */
    function getBalance(address owner, address token) public view returns (uint) {
        return __account__.balances[owner][token];
    }

    // ===== CPU Entrypoint ===== //

    /**
     * @dev Alternative entrypoint to process operations using encoded calldata transferred directly as `msg.data`.
     *
     * @custom:security Guarded against re-entrancy externally and when settling. This is the vault door, is it `locked`?.
     */
    fallback() external payable lock interactions {
        CPU.__startProcess__(_process);
    }

    /** @dev Only accepts Ether from Wrapped Ether contract. */
    receive() external payable {
        if (msg.sender != WETH) revert();
    }

    // ===== Actions ===== //

    /// @inheritdoc IHyperActions
    function syncPool(uint64 poolId) external override returns (uint128 blockTimestamp) {
        blockTimestamp; // TODO
        _syncPoolPrice(poolId);
    }

    /// @inheritdoc IHyperActions
    function allocate(
        uint64 poolId,
        uint amount
    ) external lock interactions returns (uint deltaAsset, uint deltaQuote) {
        bool useMax = amount == type(uint256).max; // magic variable.
        uint128 input = asm.toUint128(useMax ? type(uint128).max : amount);
        (deltaAsset, deltaQuote) = _allocate(useMax ? 1 : 0, poolId, input);
    }

    /// @inheritdoc IHyperActions
    function unallocate(
        uint64 poolId,
        uint amount
    ) external lock interactions returns (uint deltaAsset, uint deltaQuote) {
        bool useMax = amount == type(uint256).max; // magic variable.
        uint128 input = asm.toUint128(useMax ? type(uint128).max : amount);
        (deltaAsset, deltaQuote) = _unallocate(useMax ? 1 : 0, poolId, uint24(poolId >> 40), input);
    }

    /// @inheritdoc IHyperActions
    function stake(uint64 poolId) external lock interactions {
        _stake(poolId);
    }

    /// @inheritdoc IHyperActions
    function unstake(uint64 poolId) external lock interactions {
        _unstake(poolId);
    }

    /// @inheritdoc IHyperActions
    function swap(
        uint64 poolId,
        bool sellAsset,
        uint amount,
        uint limit
    ) external lock interactions returns (uint output, uint remainder) {
        bool useMax = amount == type(uint256).max; // magic variable.
        uint128 input = useMax ? type(uint128).max : asm.toUint128(amount);
        if (limit == type(uint256).max) limit = type(uint128).max;
        Order memory args = Order({
            useMax: useMax ? 1 : 0,
            poolId: poolId,
            input: input,
            limit: asm.toUint128(limit),
            direction: sellAsset ? 0 : 1
        });
        (, remainder, , output) = _swapExactIn(args);
    }

    /// @inheritdoc IHyperActions
    function draw(address token, uint256 amount, address to) external lock interactions {
        if (__account__.balances[msg.sender][token] < amount) revert DrawBalance(); // Only withdraw if user has enough.
        _applyDebit(token, amount);
        _decreaseReserves(token, amount);

        if (token == WETH) __dangerousUnwrapEther__(WETH, to, amount);
        else SafeTransferLib.safeTransfer(ERC20(token), to, amount);
    }

    /// @inheritdoc IHyperActions
    function fund(address token, uint256 amount) external override lock interactions {
        _applyCredit(token, amount);
        __account__.dangerousFund(token, address(this), amount); // Pulls tokens, settlement credits msg.sender.
    }

    /// @inheritdoc IHyperActions
    function deposit() external payable override lock interactions {
        _applyCredit(WETH, msg.value);
        _increaseReserves(WETH, msg.value);
        emit Deposit(msg.sender, msg.value);
    }

    // ===== Internal ===== //

    /** @dev Overridable in tests.  */
    function _blockTimestamp() internal view virtual returns (uint128) {
        return uint128(block.timestamp);
    }

    /** @dev Overridable in tests.  */
    function _liquidityPolicy() internal view virtual returns (uint256) {
        return JUST_IN_TIME_LIQUIDITY_POLICY;
    }

    // ===== Effects ===== //

    /**
     * @dev Adds liquidity to a position, therefore increasing liquidity in the pool and creating a "debit" balance in settlement.
     *
     * TODO: Document the requirement to ONLY change one value: liquidity or price.
     *
     * @custom:reverts If attempting to add zero liquidity.
     * @custom:reverts If attempting to add liquidity to a pool that has not been created.
     */
    function _allocate(
        uint8 useMax,
        uint64 poolId,
        uint128 deltaLiquidity
    ) internal returns (uint256 deltaAsset, uint256 deltaQuote) {
        if (deltaLiquidity == 0) revert ZeroLiquidityError();
        if (!pools.exists(poolId)) revert NonExistentPool(poolId);

        Pair memory pair = pairs[uint24(poolId >> 40)];
        if (useMax == 1) {
            // todo: consider using internal balances too, or in place of real balances.
            deltaLiquidity = (
                asm.toUint128(
                    getLiquidityMinted(
                        poolId,
                        __balanceOf__(pair.tokenAsset, msg.sender),
                        __balanceOf__(pair.tokenQuote, msg.sender)
                    )
                )
            );
        }

        // note: rounds token amounts up, so caller pays more. Prevents siphoning from unallocating rounded down amounts.
        (deltaAsset, deltaQuote) = getAllocateAmounts(poolId, deltaLiquidity);

        ChangeLiquidityParams memory args = ChangeLiquidityParams(
            msg.sender,
            poolId,
            _blockTimestamp(),
            deltaAsset,
            deltaQuote,
            pair.tokenAsset,
            pair.tokenQuote,
            int128(deltaLiquidity) // TODO: add better type safety for these conversions.
        );
        _changeLiquidity(args);
        emit log(deltaAsset, deltaQuote, "allocate");

        emit Allocate(poolId, pair.tokenAsset, pair.tokenQuote, deltaAsset, deltaQuote, deltaLiquidity);
    }

    /**
     * @dev Changing liquidity has cascading effects that alter critical state.
     *
     *  changeLiquidity
     *      syncPositionFees
     *      changePositionLiquidity
     *        syncPositionTimestamp
     *          changePoolLiquidity
     *            syncPoolTimestamp
     *              changeReserves
     *
     */
    function _changeLiquidity(ChangeLiquidityParams memory args) internal returns (uint feeAsset, uint feeQuote) {
        (HyperPool storage pool, HyperPosition storage pos) = (pools[args.poolId], positions[args.owner][args.poolId]);

        (feeAsset, feeQuote) = pos.syncPositionFees(
            pool.liquidity,
            pool.feeGrowthGlobalAsset,
            pool.feeGrowthGlobalQuote
        );
        emit FeesEarned(args.owner, args.poolId, feeAsset, args.tokenAsset, feeQuote, args.tokenQuote);

        _changePosition(args);
    }

    /**
     * @dev Syncs timestamp and liquidity for a position before triggering pool updates.
     */
    function _changePosition(ChangeLiquidityParams memory args) internal {
        if (args.deltaLiquidity < 0) {
            (uint256 distance, ) = getSecondsSincePositionUpdate(args.owner, args.poolId);
            if (_liquidityPolicy() > distance) revert JitLiquidity(distance);
            emit DecreasePosition(args.owner, args.poolId, uint128(-args.deltaLiquidity)); // TODO: Should be an explict function, unary hard to see...
        } else {
            emit IncreasePosition(args.owner, args.poolId, uint128(args.deltaLiquidity));
        }

        positions[args.owner][args.poolId].changePositionLiquidity(args.timestamp, args.deltaLiquidity);
        _changePool(args);
    }

    /**
     * @dev Syncs timestamp and liquidity for a pool before adding debits (increase reserve) or credits (decrease reserve) to settlement.
     */
    function _changePool(ChangeLiquidityParams memory args) internal {
        pools[args.poolId].changePoolLiquidity(args.timestamp, args.deltaLiquidity);

        (address asset, address quote) = (args.tokenAsset, args.tokenQuote);

        // todo: fix, was for debugging
        emit TouchedTokens(
            __account__.warm.length,
            __account__.warm,
            __account__.cached[asset],
            __account__.cached[quote]
        );

        if (args.deltaLiquidity < 0) {
            _decreaseReserves(asset, args.deltaAsset);
            _decreaseReserves(quote, args.deltaQuote);
        } else {
            // note: Reserves are used at the end of instruction processing to interactions transactions.
            _increaseReserves(asset, args.deltaAsset);
            _increaseReserves(quote, args.deltaQuote);
        }

        emit TouchedTokens(
            __account__.warm.length,
            __account__.warm,
            __account__.cached[asset],
            __account__.cached[quote]
        );
    }

    event TouchedTokens(uint amount, address[] warm, bool cachedAsset, bool cachedQuote);

    /**
     * @dev Subtracts liquidity from a position, therefore reducing liquidity in the pool and creating a "credit" balance in settlement.
     */
    function _unallocate(
        uint8 useMax,
        uint64 poolId,
        uint24 pairId,
        uint128 deltaLiquidity
    ) internal returns (uint deltaAsset, uint deltaQuote) {
        pairId; // TODO
        if (deltaLiquidity == 0) revert ZeroLiquidityError();
        if (!pools.exists(poolId)) revert NonExistentPool(poolId);
        if (useMax == 1) deltaLiquidity = asm.toUint128(positions[msg.sender][poolId].totalLiquidity);

        // note: Reserves are referenced at end of processing to determine amounts of token to transfer.
        (deltaAsset, deltaQuote) = getUnallocateAmounts(poolId, deltaLiquidity); // computed before changing liquidity

        Pair memory pair = pairs[uint24(poolId >> 40)];
        ChangeLiquidityParams memory args = ChangeLiquidityParams(
            msg.sender,
            poolId,
            _blockTimestamp(),
            deltaAsset,
            deltaQuote,
            pair.tokenAsset,
            pair.tokenQuote,
            -int128(deltaLiquidity)
        );

        emit log(deltaAsset, deltaQuote, "unallocate");
        _changeLiquidity(args);
        emit Unallocate(poolId, pair.tokenAsset, pair.tokenQuote, deltaAsset, deltaQuote, deltaLiquidity);
    }

    event log(string);
    event log(int128);
    event log(uint, uint, string);

    /**
     * @dev Adds desired amount of liquidity to pending staked liquidity changes of a pool.
     */
    function _stake(uint64 poolId) internal {
        if (!pools.exists(poolId)) revert NonExistentPool(poolId);

        HyperPosition storage pos = positions[msg.sender][poolId];
        if (pos.stakeEpochId != 0) revert PositionStakedError(poolId);
        if (pos.totalLiquidity == 0) revert PositionZeroLiquidityError(poolId);

        HyperPool storage pool = pools[poolId];
        pool.epochStakedLiquidityDelta += int128(pos.totalLiquidity);

        Epoch storage epoch = epochs[poolId];
        pos.stakeEpochId = epoch.id + 1;

        // note: do we need to update position blockTimestamp?

        // emit Stake Position
    }

    /**
     * @dev Subtracts desired amount of liquidity from pending staked liquidity changes of a pool.
     */
    function _unstake(uint64 poolId) internal {
        _syncPoolPrice(poolId); // Reverts if pool does not exist.

        HyperPosition storage pos = positions[msg.sender][poolId];
        if (pos.stakeEpochId == 0 || pos.unstakeEpochId != 0) revert PositionNotStakedError(poolId);

        HyperPool storage pool = pools[poolId];
        pool.epochStakedLiquidityDelta -= int128(pos.totalLiquidity);

        Epoch storage epoch = epochs[poolId];
        pos.unstakeEpochId = epoch.id + 1;

        // note: do we need to update position blockTimestamp?

        // emit Unstake Position
    }

    // ===== Swaps ===== //

    /**
     * @dev Computes the price of the pool, which changes over time. Syncs pool to new price if enough time has passed.
     *
     * @custom:reverts If pool does not exist.
     * @custom:reverts Underflows if the reserve of the input token is lower than the next one, after the next price movement.
     * @custom:reverts Underflows if current reserves of output token is less then next reserves.
     */
    function _syncPoolPrice(uint64 poolId) internal returns (uint256 price, int24 tick) {
        if (!pools.exists(poolId)) revert NonExistentPool(poolId);

        HyperPool storage pool = pools[poolId];

        uint timestamp = _blockTimestamp();
        Epoch memory epoch = epochs[poolId];
        uint passed = epoch.getEpochsPassed(timestamp);
        if (passed > 0) {
            uint256 tauSeconds = computeTau(poolId);
            uint256 elapsedSeconds = passed * epoch.interval;
            uint strike = Price.computePriceWithTick(pool.params.maxTick);
            Price.Expiring memory expiring = Price.Expiring(strike, pool.params.volatility, tauSeconds);

            price = expiring.computePriceWithChangeInTau(pool.lastPrice, elapsedSeconds);
            tick = Price.computeTickWithPrice(price);
            _syncPool(poolId, tick, price, pool.liquidity, pool.feeGrowthGlobalAsset, pool.feeGrowthGlobalQuote);
        }
    }

    event log(uint);
    event log(bool);

    SwapState state;

    /**
     * @dev Swaps exact input of tokens for an output of tokens in the specified direction.
     *
     * @custom:mev Must have price limit to avoid losses from flash loan price manipulations.
     * @custom:reverts If input swap amount is zero.
     * @custom:reverts If pool is not initialized with a price.
     * @custom:security Updates the pool's price in _syncPoolPrice before the swap happens.
     */
    function _swapExactIn(
        Order memory args
    ) internal returns (uint64 poolId, uint256 remainder, uint256 input, uint256 output) {
        if (args.input == 0) revert ZeroInput();
        if (!pools.exists(args.poolId)) revert NonExistentPool(args.poolId);

        Pair memory pair = pairs[uint16(args.poolId >> 40)];
        HyperPool storage pool = pools[args.poolId];

        state.sell = args.direction == 0; // args.direction == 0 ? Swap asset for quote : Swap quote for asset.
        state.feeGrowthGlobal = state.sell ? pool.feeGrowthGlobalAsset : pool.feeGrowthGlobalQuote;

        Iteration memory _swap;
        {
            // Updates price based on time passed since last update.
            (uint256 price, int24 tick) = _syncPoolPrice(args.poolId);
            // Assumes useMax flag will be used with caller's internal balance to execute multiple operations.
            remainder = args.useMax == 1
                ? getBalance(msg.sender, state.sell ? pair.tokenAsset : pair.tokenQuote)
                : args.input;
            // Begin the iteration at the live price, using the total swap input amount as the remainder to fill.
            _swap = Iteration({
                price: price,
                tick: tick,
                feeAmount: 0,
                remainder: remainder,
                liquidity: pool.liquidity,
                input: 0,
                output: 0
            });
        }

        Price.Expiring memory expiring;
        {
            Epoch memory epoch = epochs[poolId];
            uint timestamp = _blockTimestamp();
            emit log("computing tau");
            uint tau = computeTau(poolId);
            emit log(tau);
            if (tau == 0) revert PoolExpiredError();

            uint strike = Price.computePriceWithTick(pool.params.maxTick);
            emit log(tau, strike, "tau strike");
            // todo: fix this with buffer too
            expiring = Price.Expiring({strike: strike, sigma: pool.params.volatility, tau: tau});

            state.gamma = 1e4 - pool.params.fee;
        }

        emit log("here");
        // =---= Effects =---= //

        uint256 liveIndependent;
        uint256 nextIndependent;
        uint256 liveDependent;
        uint256 nextDependent;

        {
            uint256 deltaInput; // Amount of tokens being swapped in.
            uint256 maxInput; // Max tokens swapped in.

            // Virtual reserves.
            if (state.sell) {
                (liveDependent, liveIndependent) = expiring.computeReserves(_swap.price);
                maxInput = (PRECISION - liveIndependent).mulWadDown(_swap.liquidity); // There can be maximum 1:1 ratio between assets and liqudiity.
            } else {
                (liveIndependent, liveDependent) = expiring.computeReserves(_swap.price);
                maxInput = (expiring.strike - liveIndependent).mulWadDown(_swap.liquidity); // There can be maximum strike:1 liquidity ratio between quote and liquidity.
            }

            _swap.feeAmount =
                ((_swap.remainder >= maxInput ? maxInput : _swap.remainder) * (1e4 - state.gamma)) /
                10_000;
            state.feeGrowthGlobal = FixedPointMathLib.divWadDown(_swap.feeAmount, _swap.liquidity);

            if (_swap.remainder >= maxInput) {
                // If more than max tokens are being swapped in...
                deltaInput = maxInput - _swap.feeAmount;
                nextIndependent = liveIndependent + deltaInput.divWadDown(_swap.liquidity);
                _swap.remainder -= (deltaInput + _swap.feeAmount); // Reduce the remainder of the order to fill.
            } else {
                // Reaching this block will fill the order.
                deltaInput = _swap.remainder - _swap.feeAmount;
                nextIndependent = liveIndependent + deltaInput.divWadDown(_swap.liquidity);
                deltaInput = _swap.remainder; // Swap input amount including the fee payment.
                _swap.remainder = 0; // Clear the remainder to zero, as the order has been filled.
            }

            // Compute the output of the swap by computing the difference between the dependent reserves.
            if (state.sell) nextDependent = expiring.computeR1WithR2(nextIndependent);
            else nextDependent = expiring.computeR2WithR1(nextIndependent);

            // Apply swap amounts to swap state.
            _swap.input += deltaInput;
            _swap.output += (liveDependent - nextDependent);
        }

        {
            uint256 nextPrice;
            int256 liveInvariant;
            int256 nextInvariant;

            if (state.sell) {
                liveInvariant = expiring.invariant(liveDependent, liveIndependent);
                nextInvariant = expiring.invariant(nextDependent, nextIndependent);
                nextPrice = expiring.computePriceWithR2(nextIndependent);
            } else {
                liveInvariant = expiring.invariant(liveIndependent, liveDependent);
                nextInvariant = expiring.invariant(nextIndependent, nextDependent);
                nextPrice = expiring.computePriceWithR2(nextDependent);
            }

            _swap.price = nextPrice;
            if (_swap.price > args.limit) revert SwapLimitReached();

            // TODO: figure out invariant stuff, reverse swaps have 1e3 error (invariant goes negative by 1e3 precision).
            //if (nextInvariant < liveInvariant) revert InvariantError(liveInvariant, nextInvariant);
        }

        // Apply pool effects.
        _syncPool(
            args.poolId,
            Price.computeTickWithPrice(_swap.price),
            _swap.price,
            _swap.liquidity,
            state.sell ? state.feeGrowthGlobal : 0,
            state.sell ? 0 : state.feeGrowthGlobal
        );

        // Apply reserve effects.
        _increaseReserves(pair.tokenAsset, _swap.input);
        _decreaseReserves(pair.tokenQuote, _swap.output);

        (poolId, remainder, input, output) = (args.poolId, _swap.remainder, _swap.input, _swap.output);
        emit Swap(args.poolId, _swap.input, _swap.output, pair.tokenAsset, pair.tokenQuote);
    }

    /**
     * @dev Effects on a Pool after a successful swap order condition has been met.
     *
     * @return timeDelta Amount of time passed since the last update to the pool.
     */
    function _syncPool(
        uint64 poolId,
        int24 tick,
        uint256 price,
        uint256 liquidity,
        uint256 feeGrowthGlobalAsset,
        uint256 feeGrowthGlobalQuote
    ) internal returns (uint256 timeDelta) {
        HyperPool storage pool = pools[poolId];
        Epoch memory readEpoch = epochs[poolId];

        uint256 epochsPassed = readEpoch.getEpochsPassed(pool.lastTimestamp);
        if (epochsPassed > 0) {
            pool.stakedLiquidity = asm.__computeDelta(pool.stakedLiquidity, pool.epochStakedLiquidityDelta);
            pool.epochStakedLiquidityDelta = int128(0);
        }

        uint256 timestamp = _blockTimestamp();
        uint256 lastUpdateTime = pool.lastTimestamp;
        timeDelta = timestamp - lastUpdateTime;

        if (pool.lastTick != tick) pool.lastTick = tick;
        if (pool.lastPrice != price) pool.lastPrice = price.toUint128();
        if (pool.liquidity != liquidity) pool.liquidity = liquidity.toUint128();
        if (pool.lastTimestamp != timestamp) pool.lastTimestamp = uint32(timestamp);

        pool.feeGrowthGlobalAsset = asm.__computeCheckpoint(pool.feeGrowthGlobalAsset, feeGrowthGlobalAsset);
        pool.feeGrowthGlobalQuote = asm.__computeCheckpoint(pool.feeGrowthGlobalQuote, feeGrowthGlobalQuote);

        Pair memory pair = pairs[uint24(poolId >> 40)];
        emit PoolUpdate(
            poolId,
            pool.lastPrice,
            pool.lastTick,
            pool.liquidity,
            pair.tokenAsset,
            pair.tokenQuote,
            feeGrowthGlobalAsset,
            feeGrowthGlobalQuote
        );
    }

    // ===== Initializing Pools ===== //

    /**
     * @dev Pairs are used in pool creation to determine the pool's underlying tokens.
     *
     * @custom:reverts If decoded addresses are the same.
     * @custom:reverts If __ordered__ pair of addresses has already been created and has a non-zero pairId.
     * @custom:reverts If decimals of either token are not between 6 and 18, inclusive.
     */
    function _createPair(address asset, address quote) internal returns (uint24 pairId) {
        if (asset == quote) revert SameTokenError();

        pairId = getPairId[asset][quote];
        if (pairId != 0) revert PairExists(pairId);

        (uint8 decimalsAsset, uint8 decimalsQuote) = (IERC20(asset).decimals(), IERC20(quote).decimals());
        if (!asm.isBetween(decimalsAsset, MIN_DECIMALS, MAX_DECIMALS)) revert DecimalsError(decimalsAsset);
        if (!asm.isBetween(decimalsQuote, MIN_DECIMALS, MAX_DECIMALS)) revert DecimalsError(decimalsQuote);

        unchecked {
            pairId = uint16(++getPairNonce); // TODO: change to uint24 probably. Good chance this overflows on higher TPS networks.
        }

        getPairId[asset][quote] = pairId; // note: order of tokens matters!
        pairs[pairId] = Pair({
            tokenAsset: asset,
            decimalsAsset: decimalsAsset, // TODO: change pair struct to decimalsAsset
            tokenQuote: quote,
            decimalsQuote: decimalsQuote
        });

        emit CreatePair(pairId, asset, quote, decimalsAsset, decimalsQuote);
    }

    /**
     * @dev Uses a pair and set of parameters to instantiate a pool at a price.
     *
     *
     * @custom:magic If pairId is 0, uses current pair nonce.
     * @custom:reverts If price is 0.
     * @custom:reverts If pool with same pairId, isMutable, and poolNonce has already been created.
     * @custom:reverts If an expiring pool and the current timestamp is beyond the pool's maturity parameter.
     */
    function _createPool(
        uint24 pairId,
        address controller,
        uint16 priorityFee,
        uint16 fee,
        uint16 vol,
        uint16 dur,
        uint16 jit,
        int24 max,
        uint128 price
    ) internal returns (uint64 poolId) {
        if (price == 0) revert ZeroPrice();
        if (vol == 0) revert MinSigma(vol);
        if (dur == 0) revert InvalidDuration(dur);
        if (max >= MAX_TICK) revert InvalidTick(max);
        if (jit > JUST_IN_TIME_LIQUIDITY_POLICY * 10) revert InvalidJit(jit); // todo: do proper jit range
        if (!asm.isBetween(fee, MIN_POOL_FEE, MAX_POOL_FEE)) revert FeeOOB(fee);
        if (!asm.isBetween(priorityFee, MIN_POOL_FEE, fee)) revert PriorityFeeOOB(priorityFee);

        if (pairId == 0) pairId = uint24(getPairNonce); // magic variable

        uint32 poolNonce;
        unchecked {
            poolNonce = uint32(++getPoolNonce);
        }

        bool isMutable = controller != address(0);
        HyperPool memory params = HyperPool({
            lastTick: Price.computeTickWithPrice(price),
            lastTimestamp: uint32(_blockTimestamp()), // fix type
            controller: controller,
            feeGrowthGlobalAsset: 0,
            feeGrowthGlobalQuote: 0,
            lastPrice: price,
            liquidity: 0,
            stakedLiquidity: 0,
            epochStakedLiquidityDelta: 0,
            params: HyperCurve({
                maxTick: max,
                jit: isMutable ? jit : uint8(JUST_IN_TIME_LIQUIDITY_POLICY),
                fee: fee,
                duration: dur,
                volatility: vol,
                priorityFee: isMutable ? priorityFee : 0,
                startEpoch: currentEpoch
            })
        });

        uint64 poolId = computePoolId(pairId, isMutable, poolNonce);
        if (pools.exists(poolId)) revert PoolExists();

        epochs[poolId] = Epoch({
            id: currentEpoch,
            endTime: params.lastTimestamp + EPOCH_INTERVAL,
            interval: EPOCH_INTERVAL
        });

        pools[poolId] = params;

        emit CreatePool(poolId, uint16(pairId), 0x0, price); // todo: event
    }

    error NotController();
    error InvalidJit(uint16);
    error InvalidTick(int24);
    error InvalidDuration(uint16);

    /// TODO: add interactions modifier to this probably
    function alter(
        uint64 poolNonce,
        uint16 priorityFee,
        uint16 fee,
        uint16 vol,
        uint16 dur,
        uint16 jit,
        int24 max
    ) external lock {
        HyperPool storage pool = pools[poolNonce];
        if (pool.controller != msg.sender) revert NotController();
        if (max >= MAX_TICK) revert InvalidTick(max);
        if (jit > JUST_IN_TIME_LIQUIDITY_POLICY * 10) revert InvalidJit(jit);
        if (jit != 0) pool.params.jit = jit;
        if (max != 0) pool.params.maxTick = max;
        if (fee != 0) pool.params.fee = fee;
        if (vol != 0) pool.params.volatility = vol;
        if (dur != 0) pool.params.duration = dur;
        if (priorityFee != 0) pool.params.priorityFee = priorityFee;

        // TODO: emit an event
    }

    function computePoolId(uint24 pairId, bool isMutable, uint32 poolNonce) public view returns (uint64) {
        return uint64(bytes8(abi.encodePacked(pairId, isMutable ? uint8(1) : uint8(0), poolNonce)));
    }

    // todo: maybe hash? this is not used anywhere right now.
    function computeRawParams(HyperPool memory params) public view returns (bytes32) {
        return
            CPU.toBytes32(
                abi.encodePacked(
                    params.controller,
                    params.params.priorityFee,
                    params.params.fee,
                    params.params.volatility,
                    params.params.duration,
                    params.params.jit,
                    params.params.maxTick
                )
            );
    }

    function computeTau(uint64 poolId) public view returns (uint) {
        HyperPool storage pool = pools[poolId];
        Epoch memory epoch = epochs[poolId];
        uint timestamp = _blockTimestamp();
        uint current = epoch.getEpochsPassed(timestamp);
        //if (current > pool.params.duration) return 0; // expired

        uint computedTau = uint(pool.params.duration - current) * EPOCH_INTERVAL;
        return computedTau;
    }

    function isMutable(uint64 poolId) public view returns (bool) {
        return pools[poolId].controller != address(0);
    }

    // ===== Accounting System ===== //
    /**
     * @dev Reserves are an internally tracked amount of tokens that should match the return value of `balanceOf`.
     *
     * @custom:security Directly manipulates reserves.
     */
    function _increaseReserves(address token, uint256 amount) internal {
        __account__.increase(token, amount);
        emit IncreaseReserveBalance(token, amount);
    }

    /**
     * @dev Reserves are an internally tracked amount of tokens that should match the return value of `balanceOf`.
     *
     * @custom:security Directly manipulates reserves.
     * @custom:reverts With `InsufficientBalance` if current reserve balance for `token` iss less than `amount`.
     */
    function _decreaseReserves(address token, uint256 amount) internal {
        __account__.decrease(token, amount);
        emit DecreaseReserveBalance(token, amount);
    }

    /**
     * @dev A positive credit is a receivable paid to the `msg.sender` internal balance.
     *      Positive credits are only applied to the internal balance of the account.
     *      Therefore, it does not require a state change for the global reserves.
     *
     * @custom:security Directly manipulates intrernal balances.
     */
    function _applyCredit(address token, uint256 amount) internal {
        __account__.credit(msg.sender, token, amount);
        emit IncreaseUserBalance(token, amount);
    }

    /**
     * @dev A positive debit is a cost that must be paid for a transaction to be processed.
     *      If a balance exists for the token for the internal balance of `msg.sender`,
     *      it will be used to pay the debit. Else, the contract expects tokens to be transferred in.
     *
     * @custom:security Directly manipulates intrernal balances.
     */
    function _applyDebit(address token, uint256 amount) internal {
        __account__.debit(msg.sender, token, amount);
        emit DecreaseUserBalance(token, amount);
    }

    /**
     * @dev Alternative entrypoint to execute functions.
     *
     * @param data Encoded Enigma data. First byte must be an Enigma instruction.
     *
     * @custom:reverts If encoded data does not match the decoding format for the instruction specified.
     */
    function _process(bytes calldata data) internal {
        (, bytes1 instruction) = CPU.separate(data[0]); // Upper byte is useMax, lower byte is instruction.

        if (instruction == CPU.ALLOCATE) {
            (uint8 useMax, uint64 poolId, uint128 deltaLiquidity) = CPU.decodeAllocate(data); // Packs the use max flag in the Enigma instruction code byte.
            _allocate(useMax, poolId, deltaLiquidity);
        } else if (instruction == CPU.UNALLOCATE) {
            (uint8 useMax, uint64 poolId, uint24 pairId, uint128 deltaLiquidity) = CPU.decodeUnallocate(data); // Packs useMax flag into Enigma instruction code byte.
            _unallocate(useMax, poolId, pairId, deltaLiquidity);
        } else if (instruction == CPU.SWAP) {
            Order memory args;
            (args.useMax, args.poolId, args.input, args.limit, args.direction) = CPU.decodeSwap(data); // Packs useMax flag into Enigma instruction code byte.
            _swapExactIn(args);
        } else if (instruction == CPU.STAKE_POSITION) {
            uint64 poolId = CPU.decodeStakePosition(data);
            _stake(poolId);
        } else if (instruction == CPU.UNSTAKE_POSITION) {
            uint64 poolId = CPU.decodeUnstakePosition(data);
            _unstake(poolId);
        } else if (instruction == CPU.CREATE_POOL) {
            (
                uint24 pairId,
                address controller,
                uint16 priorityFee,
                uint16 fee,
                uint16 vol,
                uint16 dur,
                uint16 jit,
                int24 max,
                uint128 price
            ) = CPU.decodeCreatePool(data);
            _createPool(pairId, controller, priorityFee, fee, vol, dur, jit, max, price);
        } else if (instruction == CPU.CREATE_PAIR) {
            (address asset, address quote) = CPU.decodeCreatePair(data);
            _createPair(asset, quote);
        } else {
            revert UnknownInstruction();
        }
    }

    // ===== View ===== //

    /** @dev Computes amount of liquidity added to position and pool if token amounts were provided. */
    function getLiquidityMinted(
        uint64 poolId,
        uint deltaAsset,
        uint deltaQuote
    ) public view returns (uint128 deltaLiquidity) {
        (uint amount0, uint amount1) = _getAmounts(poolId);
        uint liquidity0 = deltaAsset.divWadDown(amount0); // If `deltaAsset` is twice as much as assets per liquidity in pool, we can mint 2 liquidity.
        uint liquidity1 = deltaQuote.divWadDown(amount1); // If this liquidity amount is lower, it means we don't have enough tokens to mint the above amount.
        deltaLiquidity = asm.toUint128(liquidity0 < liquidity1 ? liquidity0 : liquidity1);
    }

    /** @dev Computes total amount of reserves entitled to the total liquidity of a pool. */
    function getVirtualReserves(uint64 poolId) public view returns (uint128 deltaAsset, uint128 deltaQuote) {
        uint deltaLiquidity = pools[poolId].liquidity;
        (deltaAsset, deltaQuote) = getUnallocateAmounts(poolId, deltaLiquidity);
    }

    /** @dev Computes amount of phsyical reserves entitled to amount of liquidity in a pool. Rounded down. */
    function getUnallocateAmounts(
        uint64 poolId,
        uint256 deltaLiquidity
    ) public view returns (uint128 deltaAsset, uint128 deltaQuote) {
        if (deltaLiquidity == 0) return (deltaAsset, deltaQuote);

        require(deltaLiquidity < 2 ** 127, "err above uint127");
        (uint amountAsset, uint amountQuote) = _getAmounts(poolId);

        deltaAsset = asm.toUint128(amountAsset.mulWadDown(deltaLiquidity));
        deltaQuote = asm.toUint128(amountQuote.mulWadDown(deltaLiquidity));
    }

    /** @dev Computes amount of physical reserves that must be added to the pool for `deltaLiquidity`. Rounded up. */
    function getAllocateAmounts(
        uint64 poolId,
        uint256 deltaLiquidity
    ) public view returns (uint128 deltaAsset, uint128 deltaQuote) {
        if (deltaLiquidity == 0) return (deltaAsset, deltaQuote);

        require(deltaLiquidity < 2 ** 127, "err above uint127");
        (uint amountAsset, uint amountQuote) = _getAmounts(poolId);

        deltaAsset = asm.toUint128(amountAsset.mulWadUp(deltaLiquidity));
        deltaQuote = asm.toUint128(amountQuote.mulWadUp(deltaLiquidity));
    }

    /** @dev Computes each side of a pool's reserves __per one unit of liquidity__. */
    function _getAmounts(uint64 poolId) internal view returns (uint256 deltaAsset, uint256 deltaQuote) {
        // TODO: Make a note of the importance of using the pool's _unchanged_ timestamp.
        // If the blockTimestamp of a pool changes, it will change the pool's price.
        // This blockTimestamp variable should be updated in swaps, not liquidity provision or removing.
        HyperPool storage pool = pools[poolId];
        uint256 timestamp = pool.lastTimestamp;

        Epoch memory epoch = epochs[poolId];
        uint elapsed = epoch.getEpochsPassed(timestamp) * epoch.interval; // todo: fix epoch time
        uint tau = uint32((pool.params.duration - uint16(elapsed))) * epoch.interval;
        Price.Expiring memory info = Price.Expiring({
            strike: Price.computePriceWithTick(pool.params.maxTick),
            sigma: pool.params.volatility,
            tau: tau
        });

        deltaAsset = info.computeR2WithPrice(pool.lastPrice);
        deltaQuote = info.computeR1WithR2(deltaAsset);
    }

    /** @dev Computes the time elapsed since position of `account` was last updated. */
    function getSecondsSincePositionUpdate(
        address account,
        uint64 poolId
    ) public view returns (uint256 distance, uint256 timestamp) {
        uint256 previous = positions[account][poolId].blockTimestamp;
        timestamp = _blockTimestamp();
        distance = timestamp - previous;
    }

    /** @dev TODO: Do we want to expose this? */
    function getNetBalance(address token) public view returns (int) {
        return __account__.getNetBalance(token, address(this));
    }
}

using {changePoolLiquidity} for HyperPool;
using {exists} for mapping(uint64 => HyperPool);
using {changePositionLiquidity, syncPositionFees} for HyperPosition;

/**
 * @notice Syncs a pool's liquidity and last updated timestamp.
 */
function changePoolLiquidity(HyperPool storage self, uint256 timestamp, int128 liquidityDelta) {
    // TODO: Investigate updating timestamp.
    // Changing timestamp changes pool price.
    // Cannot change price and liquidity.
    // self.blockTimestamp = timestamp;
    self.liquidity = asm.toUint128(asm.__computeDelta(self.liquidity, liquidityDelta));
}

/**
 * @notice Syncs a position's liquidity, last updated timestamp, fees earned, and fee growth.
 */
function changePositionLiquidity(HyperPosition storage self, uint256 timestamp, int128 liquidityDelta) {
    self.blockTimestamp = timestamp; // Allowed to change timestamp with changing liquidity of a position.
    self.totalLiquidity = asm.toUint128(asm.__computeDelta(self.totalLiquidity, liquidityDelta));
}

function syncPositionFees(
    HyperPosition storage self,
    uint liquidity,
    uint feeGrowthAsset,
    uint feeGrowthQuote
) returns (uint feeAssetEarned, uint feeQuoteEarned) {
    uint checkpointAsset = asm.__computeCheckpointDistance(feeGrowthAsset, self.feeGrowthAssetLast);
    uint checkpointQuote = asm.__computeCheckpointDistance(feeGrowthQuote, self.feeGrowthQuoteLast);

    feeAssetEarned = FixedPointMathLib.mulWadDown(checkpointAsset, liquidity);
    feeQuoteEarned = FixedPointMathLib.mulWadDown(checkpointQuote, liquidity);

    self.feeGrowthAssetLast = feeGrowthAsset;
    self.feeGrowthQuoteLast = feeGrowthQuote;

    self.tokensOwedAsset += asm.toUint128(feeAssetEarned);
    self.tokensOwedQuote += asm.toUint128(feeAssetEarned);
}

function exists(mapping(uint64 => HyperPool) storage pools, uint64 poolId) view returns (bool) {
    return pools[poolId].lastTimestamp != 0;
}
