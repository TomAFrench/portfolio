pragma solidity ^0.8.0;

import "../Compiler.sol";
import "hardhat/console.sol";

contract TestCompiler is Compiler {
    uint256 public timestamp;

    function setTimestamp(uint256 timestamp_) public {
        timestamp = timestamp_;
    }

    function _blockTimestamp() internal view override(EnigmaVirtualMachine) returns (uint128) {
        return uint128(timestamp);
    }

    function setTokens(
        uint16 pairId,
        address base,
        address quote
    ) public {
        pairs[pairId] = Pair({
            tokenBase: base,
            decimalsBase: IERC20(base).decimals(),
            tokenQuote: quote,
            decimalsQuote: IERC20(quote).decimals()
        });
    }

    function setLiquidity(
        uint48 poolId,
        uint256 base,
        uint256 quote,
        uint256 liquidity
    ) public {
        pools[poolId] = Pool({
            internalBase: uint128(base),
            internalQuote: uint128(quote),
            internalLiquidity: uint128(liquidity),
            blockTimestamp: uint128(block.timestamp)
        });
    }

    function setCurve(
        uint32 curveId,
        uint128 strike,
        uint24 sigma,
        uint32 maturity,
        uint32 gamma
    ) public {
        curves[curveId] = Curve({strike: strike, sigma: sigma, maturity: maturity, gamma: gamma});
    }

    // --- Create --- //

    function testCreatePair(bytes calldata data) public returns (uint16) {
        return _createPair(data);
    }

    function testCreateCurve(bytes calldata data) public returns (uint32) {
        return _createCurve(data);
    }

    function testCreatePool(bytes calldata data)
        public
        returns (
            uint48,
            uint256,
            uint256
        )
    {
        return _createPool(data);
    }

    function testRemoveLiquidity(bytes calldata data)
        public
        returns (
            uint48,
            uint256,
            uint256
        )
    {
        return _removeLiquidity(data);
    }

    function testAddLiquidity(bytes calldata data) public returns (uint48, uint256) {
        return _addLiquidity(data);
    }

    function testSwapExactTokens(bytes calldata data) public returns (uint48, uint256) {
        return _swapExactTokens(data);
    }

    /// @dev Should be formatted like a jump instruction set with a INSTRUCTION_JUMP opcode.
    function testJumpProcess(bytes calldata data) public returns (uint256) {
        _jumpProcess(data);
    }

    function testMain(bytes calldata data) public {
        if (data[0] != INSTRUCTION_JUMP) {
            _process(data);
        } else {
            _jumpProcess(data);
        }

        _settleBalances();
    }

    // -- Test --

    function testGetLiquidityMinted(
        uint48 poolId,
        uint256 deltaBase,
        uint256 deltaQuote
    )
        public
        view
        returns (
            uint256 deltaLiquidity,
            uint256 deltaQuote2,
            uint256 deltaLiquidity2
        )
    {
        deltaLiquidity = getLiquidityMinted(poolId, deltaBase, deltaQuote);
        (deltaLiquidity2, deltaQuote2) = getLiquidityMinted2(poolId, deltaBase);
    }

    function getLiquidityMinted2(uint48 poolId, uint256 deltaBase)
        public
        view
        returns (uint256 deltaLiquidity, uint256 deltaQuote)
    {
        Pool memory pool = pools[poolId];
        uint256 liquidity0 = (deltaBase * pool.internalLiquidity) / uint256(pool.internalBase);
        deltaQuote = (uint256(pool.internalBase) * liquidity0) / uint256(pool.internalLiquidity);
        deltaLiquidity = liquidity0;
        uint256 liquidity1 = (deltaQuote * pool.internalLiquidity) / uint256(pool.internalQuote);
        uint256 deltaLiquidity1 = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
    }

    function testGetReportedPrice(
        uint256 scaleFactorRisky,
        uint256 scaleFactorStable,
        uint256 riskyPerLiquidity,
        uint256 strike,
        uint256 sigma,
        uint256 tau
    ) public view returns (int128) {
        return
            ReplicationMath.getReportedPrice(
                scaleFactorRisky,
                scaleFactorStable,
                riskyPerLiquidity,
                strike,
                sigma,
                tau
            );
    }
}