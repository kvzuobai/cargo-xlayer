// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// CargoBurner (X Layer). Receives OKB (45% of dock fee, 70% of POL fee OKB), buys CARGO on the CARGO/WOKB v3 pool
// and burns it. Every buy is bounded by the 15-min TWAP: spot within ~2% of TWAP, minOut = TWAP quote - 3%.
// Also the CARGO price oracle for CargoMiner (season >= 2 CARGO burn). No owner.

import {UniV3Lib, IV3Pool, IV3Router, IWETH9, IERC20Min} from "./UniV3Lib.sol";

interface ICargoBurnable {
    function burn(uint256) external;
}

contract CargoBurner {
    uint32 public constant TWAP_SECS = 900;
    int24 public constant MAX_DEV = 200; // ~2% spot vs TWAP
    uint256 public constant SLIPPAGE_BPS = 300; // pool fee + impact

    IV3Pool public immutable pool;
    IV3Router public immutable router;
    IWETH9 public immutable wokb;
    address public immutable cargo;
    uint24 public immutable fee;

    uint256 public totalOkbIn;
    uint256 public totalBurned;
    uint256 private locked = 1;

    event Burned(address indexed caller, uint256 okb, uint256 cargo);

    error Reentrant();
    error BadPool();
    error PriceMoved();
    error Nothing();

    modifier nonReentrant() {
        if (locked != 1) revert Reentrant();
        locked = 2;
        _;
        locked = 1;
    }

    constructor(address pool_, address router_, address wokb_, address cargo_) {
        pool = IV3Pool(pool_);
        router = IV3Router(router_);
        wokb = IWETH9(wokb_);
        cargo = cargo_;
        address t0 = pool.token0();
        address t1 = pool.token1();
        if (!((t0 == cargo_ && t1 == wokb_) || (t0 == wokb_ && t1 == cargo_))) revert BadPool();
        fee = pool.fee();
        IERC20Min(wokb_).approve(router_, type(uint256).max);
    }

    receive() external payable {}

    /// Anyone: grow the pool's TWAP history (needed once after pool creation).
    function prepare(uint16 cardinality) external {
        pool.increaseObservationCardinalityNext(cardinality);
    }

    /// CARGO worth `okb` at the 15-min TWAP.
    function cargoForOkb(uint256 okb) public view returns (uint256) {
        return UniV3Lib.quoteAtTick(UniV3Lib.twapTick(pool, TWAP_SECS), uint128(okb), address(wokb), cargo);
    }

    /// Anyone (keeper): spend up to `maxIn` OKB (0 = all) on CARGO and burn it.
    function burn(uint256 maxIn) external nonReentrant returns (uint256 out) {
        uint256 amt = address(this).balance;
        if (maxIn != 0 && maxIn < amt) amt = maxIn;
        if (amt == 0) revert Nothing();
        int24 d = UniV3Lib.spotTick(pool) - UniV3Lib.twapTick(pool, TWAP_SECS);
        if (d > MAX_DEV || d < -MAX_DEV) revert PriceMoved();
        uint256 minOut = cargoForOkb(amt) * (10_000 - SLIPPAGE_BPS) / 10_000;
        wokb.deposit{value: amt}();
        router.exactInputSingle(
            IV3Router.ExactInputSingleParams(address(wokb), cargo, fee, address(this), amt, minOut, 0)
        );
        out = IERC20Min(cargo).balanceOf(address(this)); // includes any CARGO sent here: all of it burns
        ICargoBurnable(cargo).burn(out);
        totalOkbIn += amt;
        totalBurned += out;
        emit Burned(msg.sender, amt, out);
    }
}
