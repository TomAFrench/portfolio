// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.4;

import "./setup/HandlerBase.sol";
import "solmate/utils/SafeCastLib.sol";

contract HandlerPortfolio is HandlerBase {
    using SafeCastLib for uint256;

    function callSummary() external view {
        console.log("deposit", calls["deposit"]);
        console.log("fund-asset", calls["fund-asset"]);
        console.log("fund-quote", calls["fund-quote"]);
        console.log("create", calls["create"]);
        console.log("allocate", calls["allocate"]);
        console.log("deallocate", calls["deallocate"]);
    }

    function deposit(
        uint256 amount,
        uint256 seed
    ) external countCall("deposit") createActor useActor(seed) usePool(seed) {
        amount = bound(amount, 1, 1e36);

        vm.deal(ctx.actor(), amount);

        address weth = ctx.subject().WETH();

        uint256 preBal = ctx.ghost().balance(ctx.actor(), weth);
        uint256 preRes = ctx.ghost().reserve(weth);

        ctx.subject().deposit{value: amount}();

        uint256 postRes = ctx.ghost().reserve(weth);
        uint256 postBal = ctx.ghost().balance(ctx.actor(), weth);

        assertEq(postRes, preRes + amount, "weth-reserve");
        assertEq(postBal, preBal + amount, "weth-balance");
        assertEq(address(ctx.subject()).balance, 0, "eth-balance");
        assertEq(ctx.ghost().physicalBalance(weth), postRes, "weth-physical");
    }

    function fund_asset(
        uint256 amount,
        uint256 seed
    ) public countCall("fund-asset") createActor useActor(seed) usePool(seed) {
        amount = bound(amount, 1, 1e36);

        // If net balance > 0, there are tokens in the contract which are not in a pool or balance.
        // They will be credited to the msg.sender of the next call.
        int256 netAssetBalance = ctx.subject().getNetBalance(address(ctx.ghost().asset().to_token()));
        int256 netQuoteBalance = ctx.subject().getNetBalance(address(ctx.ghost().quote().to_token()));
        assertTrue(netAssetBalance >= 0, "negative-net-asset-tokens");
        assertTrue(netQuoteBalance >= 0, "negative-net-quote-tokens");

        ctx.ghost().asset().to_token().approve(address(ctx.subject()), amount);
        deal(address(ctx.ghost().asset().to_token()), ctx.actor(), amount);

        uint256 preRes = ctx.ghost().reserve(address(ctx.ghost().asset().to_token()));
        uint256 preBal = ctx.ghost().balance(ctx.actor(), address(ctx.ghost().asset().to_token()));

        ctx.subject().fund(address(ctx.ghost().asset().to_token()), amount);
        uint256 postRes = ctx.ghost().reserve(address(ctx.ghost().asset().to_token()));
        uint256 postBal = ctx.ghost().balance(ctx.actor(), address(ctx.ghost().asset().to_token()));

        assertEq(postBal, preBal + amount + uint256(netAssetBalance), "fund-delta-asset-balance");
        assertEq(postRes, preRes + amount + uint256(netQuoteBalance), "fund-delta-asset-reserve");
    }

    function fund_quote(
        uint256 amount,
        uint256 seed
    ) public countCall("fund-quote") createActor useActor(seed) usePool(seed) {
        amount = bound(amount, 1, 1e36);

        ctx.ghost().quote().to_token().approve(address(ctx.subject()), amount);
        deal(address(ctx.ghost().quote().to_token()), ctx.actor(), amount);

        uint256 preRes = ctx.ghost().reserve(address(ctx.ghost().quote().to_token()));
        uint256 preBal = ctx.ghost().balance(ctx.actor(), address(ctx.ghost().quote().to_token()));

        ctx.subject().fund(address(ctx.ghost().quote().to_token()), amount);
        uint256 postRes = ctx.ghost().reserve(address(ctx.ghost().quote().to_token()));
        uint256 postBal = ctx.ghost().balance(ctx.actor(), address(ctx.ghost().quote().to_token()));

        assertEq(postBal, preBal + amount, "fund-delta-quote-balance");
        assertEq(postRes, preRes + amount, "fund-delta-quote-reserve");
    }

    function create_pool(
        uint256 seed,
        uint128 price,
        uint128 terminalPrice,
        uint16 volatility,
        uint16 duration,
        uint16 fee,
        uint16 priorityFee
    ) external countCall("create") createActor useActor(seed) usePool(seed) {
        vm.assume(terminalPrice != 0);

        volatility = uint16(bound(volatility, MIN_VOLATILITY, MAX_VOLATILITY));
        duration = uint16(block.timestamp + bound(duration, MIN_DURATION, MAX_DURATION));
        price = uint128(bound(price, 1, 1e36));
        fee = uint16(bound(fee, MIN_FEE, MAX_FEE));
        priorityFee = uint16(bound(priorityFee, MIN_FEE, fee));

        // Random user
        {
            MockERC20[] memory mock_tokens = ctx.getTokens();
            address[] memory tokens = new address[](mock_tokens.length);
            for (uint256 i; i != mock_tokens.length; ++i) {
                tokens[i] = address(mock_tokens[i]);
            }

            tokens = shuffle(seed, tokens);
            address token0 = tokens[0];
            address token1 = tokens[1];
            assertTrue(token0 != token1, "same-token");

            CreateArgs memory args =
                CreateArgs(ctx.actor(), token0, token1, price, terminalPrice, volatility, duration, fee, priorityFee);
            _assertCreatePool(args);
        }
    }

    function shuffle(uint256 random, address[] memory array) internal pure returns (address[] memory output) {
        for (uint256 i = 0; i < array.length; i++) {
            uint256 n = i + (random % (array.length - i));
            address temp = array[n];
            array[n] = array[i];
            array[i] = temp;
        }

        output = array;
    }

    struct CreateArgs {
        address caller;
        address token0;
        address token1;
        uint128 price;
        uint128 terminalPrice;
        uint16 volatility;
        uint16 duration;
        uint16 fee;
        uint16 priorityFee;
    }

    bytes[] instructions;

    function _assertCreatePool(CreateArgs memory args) internal {
        bool isMutable = true;
        uint24 pairId = ctx.subject().getPairId(args.token0, args.token1);
        {
            // PortfolioPair not created? Push a create pair call to the stack.
            if (pairId == 0) instructions.push(FVM.encodeCreatePair(args.token0, args.token1));

            // Push create pool to stack
            instructions.push(
                FVM.encodeCreatePool(
                    pairId,
                    address(0),
                    args.priorityFee, // priorityFee
                    args.fee, // fee
                    args.volatility, // vol
                    args.duration, // dur
                    4, // jit
                    args.terminalPrice,
                    args.price
                )
            ); // temp
        }
        bytes memory payload = FVM.encodeJumpInstruction(instructions);

        try ctx.subject().multiprocess(payload) {
            console.log("Successfully created a pool.");
        } catch {
            console.log("Errored on attempting to create a pool.");
        }

        // Refetch the poolId. Current poolId could be "magic" zero variable.
        pairId = ctx.subject().getPairId(args.token0, args.token1);
        assertTrue(pairId != 0, "pair-not-created");

        // todo: make sure we create the last pool...
        uint64 poolId = FVM.encodePoolId(pairId, isMutable, uint32(ctx.subject().getPoolNonce()));
        // Add the created pool to the list of pools.
        // todo: fix assertTrue(getPool(address(subject()), poolId).lastPrice != 0, "pool-price-zero");
        ctx.addGhostPoolId(poolId);

        // Reset instructions so we don't use some old payload data...
        delete instructions;
    }

    function fetchAccountingState() internal view returns (AccountingState memory) {
        PortfolioPosition memory position = ctx.ghost().position(ctx.actor());
        PortfolioPool memory pool = ctx.ghost().pool();
        PortfolioPair memory pair = pool.pair;

        address asset = pair.tokenAsset;
        address quote = pair.tokenQuote;

        AccountingState memory state = AccountingState(
            ctx.ghost().reserve(asset),
            ctx.ghost().reserve(quote),
            ctx.ghost().asset().to_token().balanceOf(address(ctx.subject())),
            ctx.ghost().quote().to_token().balanceOf(address(ctx.subject())),
            ctx.getBalanceSum(asset),
            ctx.getBalanceSum(quote),
            ctx.getPositionsLiquiditySum(),
            position.freeLiquidity,
            pool.liquidity,
            pool.feeGrowthGlobalAsset,
            pool.feeGrowthGlobalQuote,
            position.feeGrowthAssetLast,
            position.feeGrowthQuoteLast
        );

        return state;
    }

    function allocate(
        uint256 deltaLiquidity,
        uint256 seed
    ) public countCall("allocate") createActor useActor(seed) usePool(seed) {
        deltaLiquidity = bound(deltaLiquidity, 1, 2 ** 126);
        _assertAllocate(deltaLiquidity);
    }

    // avoid stack too deep
    uint256 expectedDeltaAsset;
    uint256 expectedDeltaQuote;
    bool transferAssetIn;
    bool transferQuoteIn;
    int256 assetCredit;
    int256 quoteCredit;
    uint256 deltaAsset;
    uint256 deltaQuote;
    uint256 userAssetBalance;
    uint256 userQuoteBalance;
    uint256 physicalAssetPayment;
    uint256 physicalQuotePayment;

    AccountingState prev;
    AccountingState post;

    function _assertAllocate(uint256 deltaLiquidity) internal {
        // TODO: cleanup reset of these
        transferAssetIn = true;
        transferQuoteIn = true;

        // Preconditions
        PortfolioPool memory pool = ctx.ghost().pool();
        uint256 lowerDecimals =
            pool.pair.decimalsAsset > pool.pair.decimalsQuote ? pool.pair.decimalsQuote : pool.pair.decimalsAsset;
        uint256 minLiquidity = 10 ** (18 - lowerDecimals);
        vm.assume(deltaLiquidity > minLiquidity);
        assertTrue(pool.lastTimestamp != 0, "Pool not initialized");
        // todo: fix assertTrue(pool.lastPrice != 0, "Pool not created with a price");

        // Amounts of tokens that will be allocated to pool.
        (expectedDeltaAsset, expectedDeltaQuote) =
            ctx.subject().getLiquidityDeltas(ctx.ghost().poolId, int128(uint128(deltaLiquidity)));

        // If net balance > 0, there are tokens in the contract which are not in a pool or balance.
        // They will be credited to the msg.sender of the next call.
        assetCredit = ctx.subject().getNetBalance(ctx.ghost().asset().to_addr());
        quoteCredit = ctx.subject().getNetBalance(ctx.ghost().quote().to_addr());

        // Net balances should always be positive outside of execution.
        assertTrue(assetCredit >= 0, "negative-net-asset-tokens");
        assertTrue(quoteCredit >= 0, "negative-net-quote-tokens");

        // Internal balance of tokens spendable by user.
        userAssetBalance = ctx.ghost().balance(address(ctx.actor()), ctx.ghost().asset().to_addr());
        userQuoteBalance = ctx.ghost().balance(address(ctx.actor()), ctx.ghost().quote().to_addr());

        // If there is a net balance, user can use it to pay their cost.
        // Total payment the user must make.
        physicalAssetPayment = uint256(assetCredit) > expectedDeltaAsset ? 0 : expectedDeltaAsset - uint256(assetCredit);
        physicalQuotePayment = uint256(quoteCredit) > expectedDeltaQuote ? 0 : expectedDeltaQuote - uint256(quoteCredit);

        physicalAssetPayment =
            uint256(userAssetBalance) > physicalAssetPayment ? 0 : physicalAssetPayment - uint256(userAssetBalance);
        physicalQuotePayment =
            uint256(userQuoteBalance) > physicalQuotePayment ? 0 : physicalQuotePayment - uint256(userQuoteBalance);

        // If user can pay for the allocate using their internal balance of tokens, don't need to transfer tokens in.
        // Won't need to transfer in tokens if user payment is zero.
        if (physicalAssetPayment == 0) transferAssetIn = false;
        if (physicalQuotePayment == 0) transferQuoteIn = false;

        // If the user has to pay externally, give them tokens.
        if (transferAssetIn) ctx.ghost().asset().to_token().mint(ctx.actor(), physicalAssetPayment);
        if (transferQuoteIn) ctx.ghost().quote().to_token().mint(ctx.actor(), physicalQuotePayment);

        // Execution
        prev = fetchAccountingState();
        // todo: fix (deltaAsset, deltaQuote) = ctx.subject().allocate(ctx.ghost().poolId, deltaLiquidity);
        post = fetchAccountingState();

        // Postconditions

        assertEq(deltaAsset, expectedDeltaAsset, "pool-delta-asset");
        assertEq(deltaQuote, expectedDeltaQuote, "pool-delta-quote");
        assertEq(post.totalPoolLiquidity, prev.totalPoolLiquidity + deltaLiquidity, "pool-total-liquidity");
        assertTrue(post.totalPoolLiquidity > prev.totalPoolLiquidity, "pool-liquidity-increases");
        assertEq(
            post.callerPositionLiquidity, prev.callerPositionLiquidity + deltaLiquidity, "position-liquidity-increases"
        );

        assertEq(post.reserveAsset, prev.reserveAsset + physicalAssetPayment + uint256(assetCredit), "reserve-asset");
        assertEq(post.reserveQuote, prev.reserveQuote + physicalQuotePayment + uint256(quoteCredit), "reserve-quote");
        assertEq(post.physicalBalanceAsset, prev.physicalBalanceAsset + physicalAssetPayment, "physical-asset");
        assertEq(post.physicalBalanceQuote, prev.physicalBalanceQuote + physicalQuotePayment, "physical-quote");

        uint256 feeDelta0 = post.feeGrowthAssetPosition - prev.feeGrowthAssetPosition;
        uint256 feeDelta1 = post.feeGrowthAssetPool - prev.feeGrowthAssetPool;
        assertTrue(feeDelta0 == feeDelta1, "asset-growth");

        uint256 feeDelta2 = post.feeGrowthQuotePosition - prev.feeGrowthQuotePosition;
        uint256 feeDelta3 = post.feeGrowthQuotePool - prev.feeGrowthQuotePool;
        assertTrue(feeDelta2 == feeDelta3, "quote-growth");

        emit FinishedCall("Allocate");

        checkVirtualInvariant();
    }

    event FinishedCall(string);

    function deallocate(
        uint256 deltaLiquidity,
        uint256 seed
    ) external countCall("deallocate") createActor useActor(seed) usePool(seed) {
        deltaLiquidity = bound(deltaLiquidity, 1, 2 ** 126);

        _assertDeallocate(deltaLiquidity);
    }

    function _assertDeallocate(uint256 deltaLiquidity) internal {
        // TODO: Add use max flag support.

        // Get some liquidity.
        PortfolioPosition memory pos = ctx.ghost().position(ctx.actor());
        require(pos.freeLiquidity >= deltaLiquidity, "Not enough liquidity");

        if (pos.freeLiquidity >= deltaLiquidity) {
            // Preconditions
            PortfolioPool memory pool = ctx.ghost().pool();
            assertTrue(pool.lastTimestamp != 0, "Pool not initialized");
            // todo: fix assertTrue(pool.lastPrice != 0, "Pool not created with a price");

            // Deallocate
            uint256 timestamp = block.timestamp + 4; // todo: fix default jit policy
            vm.warp(timestamp);

            (expectedDeltaAsset, expectedDeltaQuote) =
                ctx.subject().getLiquidityDeltas(ctx.ghost().poolId, -int128(uint128(deltaLiquidity)));
            prev = fetchAccountingState();

            ctx.subject().multiprocess(
                FVM.encodeDeallocate(uint8(0), ctx.ghost().poolId, deltaLiquidity.safeCastTo128())
            );

            AccountingState memory end = fetchAccountingState();

            assertEq(end.reserveAsset, prev.reserveAsset - expectedDeltaAsset, "reserve-asset");
            assertEq(end.reserveQuote, prev.reserveQuote - expectedDeltaQuote, "reserve-quote");
            assertEq(end.totalPoolLiquidity, prev.totalPoolLiquidity - deltaLiquidity, "total-liquidity");
            assertTrue(prev.totalPositionLiquidity >= deltaLiquidity, "total-pos-liq-underflow");
            assertTrue(prev.callerPositionLiquidity >= deltaLiquidity, "caller-pos-liq-underflow");
            assertEq(
                end.totalPositionLiquidity, prev.totalPositionLiquidity - deltaLiquidity, "total-position-liquidity"
            );
            assertEq(
                end.callerPositionLiquidity, prev.callerPositionLiquidity - deltaLiquidity, "caller-position-liquidity"
            );
        }
        emit FinishedCall("Deallocate");

        checkVirtualInvariant();
    }

    function checkVirtualInvariant() internal {
        // PortfolioPool memory pool = ctx.ghost().pool();
        // TODO: Breaks when we call this function on a pool with zero liquidity...
        (uint256 dAsset, uint256 dQuote) = ctx.subject().getReserves(ctx.ghost().poolId);
        emit log("dAsset", dAsset);
        emit log("dQuote", dQuote);

        uint256 bAsset = ctx.ghost().asset().to_token().balanceOf(address(ctx.subject()));
        uint256 bQuote = ctx.ghost().quote().to_token().balanceOf(address(ctx.subject()));

        emit log("bAsset", bAsset);
        emit log("bQuote", bQuote);

        int256 diffAsset = int256(bAsset) - int256(dAsset);
        int256 diffQuote = int256(bQuote) - int256(dQuote);
        emit log("diffAsset", diffAsset);
        emit log("diffQuote", diffQuote);

        assertTrue(bAsset >= dAsset, "invariant-virtual-reserves-asset");
        assertTrue(bQuote >= dQuote, "invariant-virtual-reserves-quote");

        emit FinishedCall("Check Virtual Invariant");
    }

    event log(string, uint256);
    event log(string, int256);
}

struct AccountingState {
    uint256 reserveAsset; // getReserve
    uint256 reserveQuote; // getReserve
    uint256 physicalBalanceAsset; // balanceOf
    uint256 physicalBalanceQuote; // balanceOf
    uint256 totalBalanceAsset; // sum of all balances from getBalance
    uint256 totalBalanceQuote; // sum of all balances from getBalance
    uint256 totalPositionLiquidity; // sum of all position liquidity
    uint256 callerPositionLiquidity; // position.freeLiquidity
    uint256 totalPoolLiquidity; // pool.liquidity
    uint256 feeGrowthAssetPool; // getPool
    uint256 feeGrowthQuotePool; // getPool
    uint256 feeGrowthAssetPosition; // getPosition
    uint256 feeGrowthQuotePosition; // getPosition
}
