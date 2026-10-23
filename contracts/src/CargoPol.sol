// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// CargoPol (X Layer). Protocol-owned liquidity on one X/WOKB Uniswap v3 pool, full range, locked forever:
// the position NFT stays here and there is no function that removes liquidity. No owner.
// Deployed twice: CARGO/WOKB (dock "cargoPol") and BEM/WOKB (dock "bemPol").
//   add()     anyone: wrap OKB, swap the WOKB surplus half into the other token (TWAP-bounded), add liquidity.
//   harvest() anyone: collect trading fees.
//             WOKB fees: 70% -> CargoBurner (buy & burn CARGO), 30% -> CargoMiner.notifyOkb (Y30 real yield).
//             CARGO fees are burned; BEM fees stay here and go back into the pool on the next add().
// Bootstrap (CARGO pool only, no founder capital): no CARGO exists before rigs mine, so bootstrap() opens the pool at a
// fixed start price P0 and places an OKB-only buy range P0 -> P0/10 from mint OKB. Miners selling CARGO into it make the
// pool two-sided. addBid() adds new OKB to the latest range while it is still all OKB; once the price has fallen into it,
// addBid() opens a new OKB-only range just below the price (at most once per 7 days), so mint OKB never sits idle long. P0 is a start quote, not a price promise.

import {UniV3Lib, IV3Pool, IV3NPM, IV3Router, IWETH9, IERC20Min} from "./UniV3Lib.sol";

interface ICargoBurn {
    function burn(uint256) external;
}

interface IMinerYield {
    function notifyOkb() external payable;
}

contract CargoPol {
    uint32 public constant TWAP_SECS = 900;
    int24 public constant MAX_DEV = 200;
    uint256 public constant SLIPPAGE_BPS = 300;
    uint256 public constant BURN_BPS = 7_000; // rest = Y30
    int24 public constant BID_WIDTH = 23_028; // 1.0001^23028 ~ 10x: buy range P0 down to P0/10
    uint16 public constant CARDINALITY = 200;
    uint256 public constant NEW_BID_GAP = 7 days;

    IV3Pool public immutable pool;
    IV3NPM public immutable npm;
    IV3Router public immutable router;
    IWETH9 public immutable wokb;
    address public immutable other;
    address public immutable cargo;
    address public immutable burner;
    address public immutable miner;
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    int24 public immutable lower;
    int24 public immutable upper;

    uint160 public immutable sqrtP0; // 0 = no bootstrap (BEM pool)

    uint256 public tokenId;
    uint256 public bidId; // latest buy range
    uint256[] public bidIds;
    uint256 public lastNewBid;
    int24 public bidLower;
    int24 public bidUpper;
    bool private fixingPrice;
    uint128 public liquidity;
    uint256 public totalOkbIn;
    uint256 public totalToBurner;
    uint256 public totalToYield;
    uint256 public totalCargoBurned;
    uint256 private locked = 1;

    event Added(uint256 okb, uint256 swapped, uint128 liq);
    event Bootstrapped(int24 tick, int24 bidLower, int24 bidUpper, uint256 okb, uint128 liq);
    event BidAdded(uint256 okb, uint128 liq);
    event Harvested(uint256 fee0, uint256 fee1, uint256 toBurner, uint256 toYield, uint256 cargoBurned);

    error Reentrant();
    error BadPool();
    error PriceMoved();
    error SendFailed();
    error NoBootstrap();
    error PoolTaken();
    error TooSoon();

    modifier nonReentrant() {
        if (locked != 1) revert Reentrant();
        locked = 2;
        _;
        locked = 1;
    }

    constructor(
        address pool_,
        address npm_,
        address router_,
        address wokb_,
        address cargo_,
        address burner_,
        address miner_,
        uint160 sqrtP0_
    ) {
        sqrtP0 = sqrtP0_;
        pool = IV3Pool(pool_);
        npm = IV3NPM(npm_);
        router = IV3Router(router_);
        wokb = IWETH9(wokb_);
        cargo = cargo_;
        burner = burner_;
        miner = miner_;
        token0 = pool.token0();
        token1 = pool.token1();
        if (token0 == wokb_) other = token1;
        else if (token1 == wokb_) other = token0;
        else revert BadPool();
        fee = pool.fee();
        int24 s = pool.tickSpacing();
        upper = (UniV3Lib.MAX_TICK / s) * s;
        lower = -upper;
        IERC20Min(token0).approve(npm_, type(uint256).max);
        IERC20Min(token1).approve(npm_, type(uint256).max);
        IERC20Min(wokb_).approve(router_, type(uint256).max);
    }

    /// OKB in from CargoDock (mint split / dock fee) or anyone; WOKB unwraps land here too.
    receive() external payable {
        if (msg.sender != address(wokb)) totalOkbIn += msg.value;
    }

    /// Anyone: grow the pool's TWAP history (needed once if the pool keeps too few observations).
    function prepare(uint16 cardinality) external {
        pool.increaseObservationCardinalityNext(cardinality);
    }

    /// Anyone (keeper): turn idle OKB / tokens into locked liquidity.
    function add() external nonReentrant returns (uint128 added) {
        int24 twap = UniV3Lib.twapTick(pool, TWAP_SECS);
        int24 d = UniV3Lib.spotTick(pool) - twap;
        if (d > MAX_DEV || d < -MAX_DEV) revert PriceMoved();
        uint256 native = address(this).balance;
        if (native > 0) wokb.deposit{value: native}();
        uint256 swapIn = _swapSurplus(twap);
        uint256 b0 = IERC20Min(token0).balanceOf(address(this));
        uint256 b1 = IERC20Min(token1).balanceOf(address(this));
        if (tokenId == 0) {
            uint256 id;
            (id, added,,) = npm.mint(
                IV3NPM.MintParams(token0, token1, fee, lower, upper, b0, b1, 0, 0, address(this), block.timestamp)
            );
            tokenId = id;
        } else {
            (added,,) = npm.increaseLiquidity(IV3NPM.IncreaseLiquidityParams(tokenId, b0, b1, 0, 0, block.timestamp));
        }
        liquidity += added;
        emit Added(native, swapIn, added);
    }

    // Swap half of the WOKB not matched by the other token's TWAP value, so both sides are about equal.
    function _swapSurplus(int24 twap) private returns (uint256 swapIn) {
        uint256 w = wokb.balanceOf(address(this));
        uint256 o = IERC20Min(other).balanceOf(address(this));
        uint256 oInW = UniV3Lib.quoteAtTick(twap, uint128(o), other, address(wokb));
        if (w <= oInW) return 0;
        swapIn = (w - oInW) / 2;
        uint256 minOut =
            UniV3Lib.quoteAtTick(twap, uint128(swapIn), address(wokb), other) * (10_000 - SLIPPAGE_BPS) / 10_000;
        router.exactInputSingle(IV3Router.ExactInputSingleParams(address(wokb), other, fee, address(this), swapIn, minOut, 0));
    }

    /// Anyone, once: open the CARGO pool at P0 and lock all idle OKB as an OKB-only buy range below P0.
    function bootstrap() external nonReentrant returns (uint128 liq) {
        if (sqrtP0 == 0 || bidId != 0 || tokenId != 0) revert NoBootstrap();
        (uint160 s,,,,,,) = pool.slot0();
        if (s == 0) {
            pool.initialize(sqrtP0);
        } else if (s != sqrtP0) {
            // someone opened it first: with zero liquidity the price can be moved back to P0 for free
            if (pool.liquidity() != 0) revert PoolTaken();
            fixingPrice = true;
            pool.swap(address(this), s > sqrtP0, 1, sqrtP0, "");
            fixingPrice = false;
        }
        pool.increaseObservationCardinalityNext(CARDINALITY);
        (, int24 tick,,,,,) = pool.slot0();
        uint256 okb;
        (okb, liq) = _newBid(tick);
        emit Bootstrapped(tick, bidLower, bidUpper, okb, liq);
    }

    /// Anyone (keeper): put new OKB into a buy range. Latest range still all OKB -> add to it; price already inside it
    /// -> open a new OKB-only range just below the price (spot near TWAP, max once per 7 days).
    function addBid() external nonReentrant returns (uint128 liq) {
        if (bidId == 0) revert NoBootstrap();
        (, int24 tick,,,,,) = pool.slot0();
        bool allOkb = token0 == cargo ? tick >= bidUpper : tick < bidLower;
        uint256 okb;
        if (allOkb) {
            okb = _wrapAll();
            (uint256 a0, uint256 a1) = token0 == cargo ? (uint256(0), okb) : (okb, uint256(0));
            (liq,,) = npm.increaseLiquidity(IV3NPM.IncreaseLiquidityParams(bidId, a0, a1, 0, 0, block.timestamp));
            liquidity += liq;
        } else {
            if (block.timestamp < lastNewBid + NEW_BID_GAP) revert TooSoon();
            int24 d = tick - UniV3Lib.twapTick(pool, TWAP_SECS);
            if (d > MAX_DEV || d < -MAX_DEV) revert PriceMoved();
            (okb, liq) = _newBid(tick);
        }
        emit BidAdded(okb, liq);
    }

    function bidCount() external view returns (uint256) {
        return bidIds.length;
    }

    // OKB-only range of BID_WIDTH next to `tick`: below the price if CARGO is token0, above the tick if token1.
    function _newBid(int24 tick) private returns (uint256 okb, uint128 liq) {
        int24 sp = pool.tickSpacing();
        int24 w = (BID_WIDTH / sp) * sp;
        int24 f = _floor(tick, sp);
        (bidLower, bidUpper) = token0 == cargo ? (f - w, f) : (f + sp, f + sp + w);
        okb = _wrapAll();
        (uint256 a0, uint256 a1) = token0 == cargo ? (uint256(0), okb) : (okb, uint256(0));
        uint256 id;
        (id, liq,,) = npm.mint(
            IV3NPM.MintParams(token0, token1, fee, bidLower, bidUpper, a0, a1, 0, 0, address(this), block.timestamp)
        );
        bidId = id;
        bidIds.push(id);
        lastNewBid = block.timestamp;
        liquidity += liq;
    }

    function _wrapAll() private returns (uint256) {
        uint256 native = address(this).balance;
        if (native > 0) wokb.deposit{value: native}();
        return wokb.balanceOf(address(this));
    }

    /// Only for the zero-liquidity price fix in bootstrap(): nothing is owed, nothing is paid.
    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata) external view {
        if (msg.sender != address(pool) || !fixingPrice || a0 > 0 || a1 > 0) revert PoolTaken();
    }

    /// Anyone (keeper): collect fees from both positions and route them.
    function harvest() external nonReentrant {
        (uint256 f0, uint256 f1) = _collect(tokenId);
        for (uint256 i; i < bidIds.length; i++) {
            (uint256 g0, uint256 g1) = _collect(bidIds[i]);
            f0 += g0;
            f1 += g1;
        }
        if (f0 == 0 && f1 == 0) return;
        (uint256 fw, uint256 fo) = token0 == address(wokb) ? (f0, f1) : (f1, f0);
        uint256 burned;
        if (other == cargo && fo > 0) {
            ICargoBurn(cargo).burn(fo);
            burned = fo;
            totalCargoBurned += fo;
        }
        uint256 toBurner;
        uint256 toYield;
        if (fw > 0) {
            wokb.withdraw(fw);
            toBurner = fw * BURN_BPS / 10_000;
            toYield = fw - toBurner;
            totalToBurner += toBurner;
            totalToYield += toYield;
            (bool ok,) = burner.call{value: toBurner}("");
            if (!ok) revert SendFailed();
            IMinerYield(miner).notifyOkb{value: toYield}();
        }
        emit Harvested(f0, f1, toBurner, toYield, burned);
    }

    function _collect(uint256 id) private returns (uint256, uint256) {
        if (id == 0) return (0, 0);
        return npm.collect(IV3NPM.CollectParams(id, address(this), type(uint128).max, type(uint128).max));
    }

    function _floor(int24 t, int24 s) private pure returns (int24) {
        int24 c = t / s;
        if (t < 0 && t % s != 0) c--;
        return c * s;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
