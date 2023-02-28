// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.4;

import "./setup/HandlerBase.sol";
import "contracts/HyperLib.sol" as HyperTypes;

contract HandlerCreatePool is HandlerBase {
    function create_pool(
        uint256 actorSeed,
        uint128 price,
        uint128 strike,
        uint24 sigma,
        uint32 maturity,
        uint32 gamma,
        uint32 priorityGamma
    ) external createActor useActor(actorSeed) {
        vm.assume(strike != 0);
        vm.assume(sigma != 0);

        maturity = uint32(block.timestamp + bound(maturity, 1, 365 days));
        price = uint128(bound(price, 1, 1e36));
        gamma = uint32(bound(sigma, 1e4 - HyperTypes.MAX_FEE, 1e4 - HyperTypes.MIN_FEE));
        priorityGamma = uint32(bound(sigma, gamma, 1e4 - HyperTypes.MIN_FEE));

        // Random user
        address caller = ctx.actor();
        address[] memory tokens = new address[](3);
        tokens[0] = ctx.ghost().asset().to_addr();
        tokens[1] = ctx.ghost().quote().to_addr();

        address[] memory shuffled = shuffle(actorSeed, tokens);
        address token0 = shuffled[0];
        address token1 = shuffled[1];
        assertTrue(token0 != token1, "same-token");

        CreateArgs memory args = CreateArgs(
            caller,
            token0,
            token1,
            price,
            strike,
            sigma,
            maturity,
            gamma,
            priorityGamma
        );
        _assertCreatePool(args);
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
        uint128 strike;
        uint24 sigma;
        uint32 maturity;
        uint32 gamma;
        uint32 priorityGamma;
    }

    bytes[] instructions;

    function _assertCreatePool(CreateArgs memory args) internal {
        bool isMutable = true;
        uint24 pairId = ctx.subject().getPairId(args.token0, args.token1);
        {
            // HyperPair not created? Push a create pair call to the stack.
            if (pairId == 0) instructions.push(HyperTypes.Enigma.encodeCreatePair(args.token0, args.token1));

            // Push create pool to stack
            instructions.push(
                HyperTypes.Enigma.encodeCreatePool(
                    pairId,
                    address(this),
                    1, // priorityFee
                    1, // fee
                    1, // vol
                    1, // dur
                    5,
                    args.strike,
                    args.price
                )
            ); // temp
        }
        bytes memory payload = HyperTypes.Enigma.encodeJumpInstruction(instructions);
        vm.prank(args.caller);
        ctx.subject().multiprocess(payload);

        // Refetch the poolId. Current poolId could be "magic" zero variable.
        pairId = ctx.subject().getPairId(args.token0, args.token1);
        assertTrue(pairId != 0, "pair-not-created");

        // todo: make sure we create the last pool...
        uint64 poolId = HyperTypes.Enigma.encodePoolId(pairId, isMutable, uint32(ctx.subject().getPoolNonce()));

        // Add the created pool to the list of pools.
        // todo: fix assertTrue(getPool(address(subject()), poolId).lastPrice != 0, "pool-price-zero");
        ctx.addGhostPoolId(poolId);

        // Reset instructions so we don't use some old payload data...
        delete instructions;
    }
}
