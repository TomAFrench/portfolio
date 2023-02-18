// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.13;

import "solstat/Invariant.sol";

using RMM01Lib for RMM01Lib.RMM global;

uint256 constant DOUBLE_WAD = 2 ether;
uint256 constant PERCENTAGE = 10_000;
uint256 constant SQRT_WAD = 1e9;
uint256 constant WAD = 1 ether;
uint256 constant YEAR = 31556953 seconds;

/**
 * @dev     Library for RMM to compute reserves, prices, and changes in reserves over time.
 * @notice  Units Glossary:
 *
 *          wad - `1 ether` == 1e18
 *          seconds - `1 seconds` == 1
 *          percentage - 10_000 == 100%
 *
 */
library RMM01Lib {
    using FixedPointMathLib for uint256;
    using FixedPointMathLib for int256;

    struct RMM {
        uint256 strike; // wad
        uint256 sigma; // 10_000 = 100%;
        uint256 tau; // seconds
    }

    error UndefinedPrice();
    error OverflowWad(int256 wad);

    // ===== Class Methods ===== //

    function invariantOf(RMM memory args, uint256 R_y, uint256 R_x) internal pure returns (int256) {
        return Invariant.invariant(R_y, R_x, args.strike, convertPercentageToWad(args.sigma), args.tau);
    }

    function getXWithPrice(RMM memory args, uint256 prc) internal pure returns (uint256 R_x) {
        R_x = getXWithPrice(prc, args.strike, args.sigma, args.tau);
    }

    function getPriceWithX(RMM memory args, uint256 R_x) internal pure returns (uint256 prc) {
        prc = getPriceWithX(R_x, args.strike, args.sigma, args.tau);
    }

    function getYWithX(RMM memory args, uint256 R_x, int256 inv) internal pure returns (uint256 R_y) {
        R_y = getYWithX(R_x, args.strike, args.sigma, args.tau, inv);
    }

    function getXWithY(RMM memory args, uint256 R_y, int256 inv) internal pure returns (uint256 R_x) {
        R_x = getXWithY(R_y, args.strike, args.sigma, args.tau, inv);
    }

    function computeReserves(
        RMM memory args,
        uint256 prc,
        int128 inv
    ) internal pure returns (uint256 R_y, uint256 R_x) {
        R_x = getXWithPrice(prc, args.strike, args.sigma, args.tau);
        R_y = getYWithX(R_x, args.strike, args.sigma, args.tau, inv);
    }

    // ===== Raw Functions ===== //

    /**
     * @dev R_y = tradingFunction(R_x, ...)
     * @param R_x WAD
     * @param stk WAD
     * @param vol percentage
     * @param tau seconds
     * @param inv WAD
     * @return R_y WAD
     */
    function getYWithX(
        uint256 R_x,
        uint256 stk,
        uint256 vol,
        uint256 tau,
        int256 inv
    ) internal pure returns (uint256 R_y) {
        R_y = Invariant.getY(R_x, stk, convertPercentageToWad(vol), tau, inv);
    }

    /**
     * @dev R_x = tradingFunction(R_y, ...)
     * @param R_y WAD
     * @param stk WAD
     * @param vol percentage
     * @param tau seconds
     * @param inv WAD
     * @return R_x WAD
     */
    function getXWithY(
        uint256 R_y,
        uint256 stk,
        uint256 vol,
        uint256 tau,
        int256 inv
    ) internal pure returns (uint256 R_x) {
        R_x = Invariant.getX(R_y, stk, convertPercentageToWad(vol), tau, inv);
    }

    /**
     * @dev Used in `getAmounts` to compute the virtual amount of assets at the pool's price.
     * @param prc WAD
     * @param stk WAD
     * @param vol percentage
     * @param tau seconds
     * @return R_x WAD
     * @custom:math R_x = 1 - Φ(( ln(S/K) + (σ²/2)τ ) / σ√τ)
     */
    function getXWithPrice(uint256 prc, uint256 stk, uint256 vol, uint256 tau) internal pure returns (uint256 R_x) {
        uint256 input = FixedPointMathLib.divWadDown(prc, stk); // todo: clarify + document whats going on here
        if (input != 0) {
            int256 ln = FixedPointMathLib.lnWad(int256(input));
            uint256 tauYears = convertSecondsToWadYears(tau);

            uint256 sigmaWad = convertPercentageToWad(vol);
            uint256 doubleSigma = (sigmaWad * sigmaWad) / uint256(Gaussian.TWO);
            uint256 halfSigmaTau = doubleSigma * tauYears;
            uint256 sqrtTauSigma = (tauYears.sqrt() * SQRT_WAD).mulWadDown(sigmaWad);

            int256 lnOverVol = (ln * Gaussian.ONE + int256(halfSigmaTau)) / int256(sqrtTauSigma);
            int256 cdf = Gaussian.cdf(lnOverVol);
            if (cdf > Gaussian.ONE) revert OverflowWad(cdf);
            R_x = uint256(Gaussian.ONE - cdf);
        }
    }

    /**
     * @dev price(R_x) = Ke^(Φ^-1(1 - R_x)σ√τ - 1/2σ^2τ)
     *      As lim_x->0, S(x) = +infinity for all tau > 0 and vol > 0.
     *      As lim_x->1, S(x) = 0 for all tau > 0 and vol > 0.
     *      If tau or vol is zero, price is equal to strike.
     * @param R_x WAD
     * @param stk WAD
     * @param vol percentage
     * @param tau seconds
     * @return prc WAD
     */
    function getPriceWithX(uint256 R_x, uint256 stk, uint256 vol, uint256 tau) internal pure returns (uint256 prc) {
        uint256 tauYears = convertSecondsToWadYears(tau);
        uint256 volWad = convertPercentageToWad(vol);

        if (uint256(Gaussian.ONE) < R_x) revert OverflowWad(int256(R_x));
        if (R_x == 0) revert UndefinedPrice(); // As lim_x->0, S(x) = +infinity.
        if (tauYears == 0 || volWad == 0) return stk; // Ke^(0 - 0) = K.
        if (R_x == uint256(Gaussian.ONE)) return stk; // As lim_x->1, S(x) = 0 for all tau > 0 and vol > 0.

        int256 input = Gaussian.ONE - int256(R_x);
        int256 ppf = Gaussian.ppf(input);
        uint256 sqrtTauSigma = (tauYears.sqrt() * SQRT_WAD).mulWadDown(volWad);
        int256 first = (ppf * int256(sqrtTauSigma)) / Gaussian.ONE; // Φ^-1(1 - R_x)σ√τ
        uint256 doubleSigma = (volWad * volWad) / uint256(Gaussian.TWO);
        int256 halfSigmaTau = int256(doubleSigma * tauYears) / Gaussian.ONE; // 1/2σ^2τ

        int256 exponent = first - halfSigmaTau;
        int256 exp = exponent.expWad();
        prc = uint256(exp).mulWadDown(stk);
    }

    // ===== Utils ===== //

    function convertSecondsToWadYears(uint256 sec) internal pure returns (uint256 yrsWad) {
        assembly {
            yrsWad := div(mul(sec, WAD), YEAR)
        }
    }

    function convertPercentageToWad(uint256 pct) internal pure returns (uint256 pctWad) {
        assembly {
            pctWad := div(mul(pct, WAD), PERCENTAGE)
        }
    }
}
