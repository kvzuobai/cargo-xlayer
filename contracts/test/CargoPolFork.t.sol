// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// forge test --match-contract CargoPolFork --fork-url https://rpc.xlayer.tech -vv
// CargoPol (locked full-range LP) + CargoBurner (TWAP-bounded buy & burn, CARGO oracle) on real X Layer Uniswap v3.

import "forge-std/Test.sol";
import {CargoToken} from "../src/CargoToken.sol";
import {CargoPol} from "../src/CargoPol.sol";
import {CargoBurner} from "../src/CargoBurner.sol";
import {UniV3Lib, IV3Pool, IV3NPM, IV3Router, IWETH9} from "../src/UniV3Lib.sol";

interface INPMx {
    function createAndInitializePoolIfNecessary(address, address, uint24, uint160) external payable returns (address);
    function ownerOf(uint256) external view returns (address);
}

interface IERC20x {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

contract YieldSink {
    uint256 public got;
    function notifyOkb() external payable { got += msg.value; }
}

contract CargoPolForkTest is Test {
    address constant BEM_POOL = 0x2CcF8aa17F5DF9Fb5D51C9de12135a913fF29f7A;
    address constant NPM = 0x315e413A11AB0df498eF83873012430ca36638Ae;
    address constant ROUTER = 0x4f0C28f5926AFDA16bf2506D5D9e57Ea190f9bcA;
    address constant BEM = 0x60e62Efa9405d6873C5deaBD4E6CC91c25363952;
    address constant WOKB = 0xe538905cf8410324e03A5A23C1c177a474D59b2b;
    uint24 constant FEE = 10_000;

    CargoToken cargo;
    IV3Pool cpool;
    CargoBurner burner;
    CargoPol cargoPol;
    CargoPol bemPol;
    YieldSink miner;

    function setUp() public {
        vm.deal(address(this), 10_000 ether);
        cargo = new CargoToken();
        cargo.setMinter(address(this));
        cargo.mint(address(this), 10_000_000e18);
        IWETH9(WOKB).deposit{value: 1_000 ether}();

        // CARGO/WOKB 1%, 1 CARGO = 0.0001 OKB
        (address t0, address t1) = address(cargo) < WOKB ? (address(cargo), WOKB) : (WOKB, address(cargo));
        uint160 sqrtP = t0 == address(cargo) ? uint160(uint256(1 << 96) / 100) : uint160(uint256(1 << 96) * 100);
        cpool = IV3Pool(INPMx(NPM).createAndInitializePoolIfNecessary(t0, t1, FEE, sqrtP));
        cargo.approve(NPM, type(uint256).max);
        IERC20x(WOKB).approve(NPM, type(uint256).max);
        IERC20x(WOKB).approve(ROUTER, type(uint256).max);
        IERC20x(BEM).approve(ROUTER, type(uint256).max);
        cargo.approve(ROUTER, type(uint256).max);
        int24 sp = 200;
        int24 up = (887272 / sp) * sp; // runtime division (literals would fold to 887272)
        (uint256 a0, uint256 a1) = t0 == address(cargo) ? (uint256(5_000_000e18), uint256(500 ether)) : (500 ether, 5_000_000e18);
        IV3NPM(NPM).mint(IV3NPM.MintParams(t0, t1, FEE, -up, up, a0, a1, 0, 0, address(this), block.timestamp));

        miner = new YieldSink();
        burner = new CargoBurner(address(cpool), ROUTER, WOKB, address(cargo));
        cargoPol = new CargoPol(address(cpool), NPM, ROUTER, WOKB, address(cargo), address(burner), address(miner), 0);
        bemPol = new CargoPol(BEM_POOL, NPM, ROUTER, WOKB, address(cargo), address(burner), address(miner), 0);
        burner.prepare(50);
        bemPol.prepare(200);
        _ageHistory();
    }

    // small two-way swaps every 60s for 16 min, so both pools have a 15-min TWAP
    function _ageHistory() internal {
        for (uint256 i; i < 16; i++) {
            vm.warp(block.timestamp + 60);
            vm.roll(block.number + 60);
            _swap(WOKB, address(cargo), 0.01 ether);
            _swap(WOKB, BEM, 0.01 ether);
        }
    }

    function _swap(address tin, address tout, uint256 amt) internal returns (uint256) {
        return IV3Router(ROUTER).exactInputSingle(IV3Router.ExactInputSingleParams(tin, tout, FEE, address(this), amt, 0, 0));
    }

    function test_tickMathMatchesPool() public view {
        (uint160 s, int24 t,,,,,) = IV3Pool(BEM_POOL).slot0();
        assertLe(UniV3Lib.getSqrtRatioAtTick(t), s);
        assertGt(UniV3Lib.getSqrtRatioAtTick(t + 1), s);
    }

    function test_oracleNearSpot() public view {
        uint256 q = burner.cargoForOkb(1 ether);
        assertApproxEqRel(q, 10_000e18, 0.01e18); // ~1% drift from the history swaps
    }

    function test_burnerBuysAndBurns() public {
        (bool ok,) = address(burner).call{value: 1 ether}("");
        assertTrue(ok);
        uint256 out = burner.burn(0);
        console.log("CARGO burned for 1 OKB", out / 1e18);
        assertGt(out, 9_600e18);
        assertEq(cargo.totalBurned(), out);
        assertEq(address(burner).balance, 0);
    }

    function test_burnerRefusesMovedPrice() public {
        _swap(WOKB, address(cargo), 30 ether); // pump spot >2% above TWAP
        (bool ok,) = address(burner).call{value: 1 ether}("");
        assertTrue(ok);
        vm.expectRevert(CargoBurner.PriceMoved.selector);
        burner.burn(0);
    }

    function test_cargoPolAddLockHarvest() public {
        (bool ok,) = address(cargoPol).call{value: 10 ether}("");
        assertTrue(ok);
        uint128 liq = cargoPol.add();
        assertGt(liq, 0);
        assertEq(INPMx(NPM).ownerOf(cargoPol.tokenId()), address(cargoPol));
        console.log("idle WOKB after add", IERC20x(WOKB).balanceOf(address(cargoPol)));

        for (uint256 i; i < 5; i++) {
            _swap(WOKB, address(cargo), 2 ether);
            _swap(address(cargo), WOKB, 20_000e18);
        }
        uint256 burnedBefore = cargo.totalBurned();
        cargoPol.harvest();
        uint256 toB = cargoPol.totalToBurner();
        uint256 toY = cargoPol.totalToYield();
        console.log("fees OKB -> burner", toB, "-> yield", toY);
        assertGt(toB, 0);
        assertEq(address(burner).balance, toB);
        assertEq(miner.got(), toY);
        assertApproxEqAbs(toB * 3, toY * 7, 10);
        assertGt(cargo.totalBurned(), burnedBefore); // CARGO-side fees burned
    }

    function test_bemPolAddHarvestKeepsBem() public {
        (bool ok,) = address(bemPol).call{value: 5 ether}("");
        assertTrue(ok);
        assertGt(bemPol.add(), 0);
        for (uint256 i; i < 3; i++) {
            uint256 got = _swap(WOKB, BEM, 1 ether);
            _swap(BEM, WOKB, got);
        }
        bemPol.harvest();
        assertGt(bemPol.totalToBurner(), 0);
        uint256 bemIdle = IERC20x(BEM).balanceOf(address(bemPol));
        assertGt(bemIdle, 0); // BEM fees kept for the pool
        (ok,) = address(bemPol).call{value: 1 ether}("");
        assertTrue(ok);
        bemPol.add(); // re-adds with the BEM surplus
        assertGt(bemPol.liquidity(), 0);
    }

    function test_addRefusesMovedPrice() public {
        (bool ok,) = address(bemPol).call{value: 1 ether}("");
        assertTrue(ok);
        _swap(WOKB, BEM, 40 ether);
        vm.expectRevert(CargoPol.PriceMoved.selector);
        bemPol.add();
    }
}

interface IV3Factory {
    function createPool(address, address, uint24) external returns (address);
}

/// Bootstrap from zero: no CARGO anywhere, pool opened by CargoPol at P0 with an OKB-only buy range.
contract CargoPolBootstrapForkTest is Test {
    address constant FACTORY = 0x4B2ab38DBF28D31D467aA8993f6c2585981D6804;
    address constant NPM = 0x315e413A11AB0df498eF83873012430ca36638Ae;
    address constant ROUTER = 0x4f0C28f5926AFDA16bf2506D5D9e57Ea190f9bcA;
    address constant WOKB = 0xe538905cf8410324e03A5A23C1c177a474D59b2b;
    uint24 constant FEE = 10_000;

    CargoToken cargo;
    IV3Pool pool;
    CargoPol pol;
    CargoBurner burner;
    YieldSink miner;
    uint160 sqrtP0; // 1 CARGO = 0.0001 OKB

    function setUp() public {
        vm.deal(address(this), 1_000 ether);
        cargo = new CargoToken();
        cargo.setMinter(address(this)); // stands in for the miner
        pool = IV3Pool(IV3Factory(FACTORY).createPool(address(cargo), WOKB, FEE));
        sqrtP0 = address(cargo) < WOKB ? uint160(uint256(1 << 96) / 100) : uint160(uint256(1 << 96) * 100);
        miner = new YieldSink();
        burner = new CargoBurner(address(pool), ROUTER, WOKB, address(cargo));
        pol = new CargoPol(address(pool), NPM, ROUTER, WOKB, address(cargo), address(burner), address(miner), sqrtP0);
        cargo.approve(ROUTER, type(uint256).max);
        IERC20x(WOKB).approve(ROUTER, type(uint256).max);
        (bool ok,) = address(pol).call{value: 10 ether}(""); // mint OKB from the dock
        assertTrue(ok);
    }

    function _sellCargo(uint256 amt) internal returns (uint256) {
        cargo.mint(address(this), amt);
        return IV3Router(ROUTER).exactInputSingle(
            IV3Router.ExactInputSingleParams(address(cargo), WOKB, FEE, address(this), amt, 0, 0)
        );
    }

    function test_bootstrapPlacesOkbOnlyBid() public {
        uint128 liq = pol.bootstrap();
        assertGt(liq, 0);
        (uint160 s,,,,,,) = pool.slot0();
        assertEq(s, sqrtP0);
        assertEq(INPMx(NPM).ownerOf(pol.bidId()), address(pol));
        assertLt(IERC20x(WOKB).balanceOf(address(pol)), 1e6); // all OKB in the range
        assertEq(cargo.totalSupply(), 0); // no CARGO needed
        vm.expectRevert(CargoPol.NoBootstrap.selector);
        pol.bootstrap();
        console.log("bid ticks", uint256(int256(pol.bidUpper() - pol.bidLower())));
    }

    function test_minerSellsIntoBidThenBurnerWorks() public {
        pol.bootstrap();
        vm.warp(block.timestamp + 1000);
        uint256 okbOut = _sellCargo(10_000e18);
        console.log("OKB for 10k CARGO", okbOut);
        assertGt(okbOut, 0.9 ether); // ~0.0001 OKB each minus fee
        pol.harvest(); // seller paid fee in CARGO -> burned
        assertGt(cargo.totalBurned(), 0);

        vm.warp(block.timestamp + 1000); // TWAP catches up
        (bool ok,) = address(burner).call{value: 0.1 ether}("");
        assertTrue(ok);
        uint256 burned = burner.burn(0);
        console.log("burner CARGO for 0.1 OKB", burned / 1e18);
        assertGt(burned, 0);
    }

    function test_addBidAddsNewOkb() public {
        uint128 l0 = pol.bootstrap();
        (bool ok,) = address(pol).call{value: 5 ether}("");
        assertTrue(ok);
        uint128 l1 = pol.addBid();
        assertApproxEqRel(uint256(l1), uint256(l0) / 2, 0.01e18);
    }

    function test_addBidOpensNewRangeWhenPriceInside() public {
        pol.bootstrap();
        vm.warp(block.timestamp + 1000);
        _sellCargo(20_000e18); // price falls into the first range
        vm.warp(block.timestamp + 1000); // TWAP catches up
        (bool ok,) = address(pol).call{value: 3 ether}("");
        assertTrue(ok);
        vm.expectRevert(CargoPol.TooSoon.selector); // < 7 days since bootstrap
        pol.addBid();
        vm.warp(block.timestamp + 7 days);
        uint256 first = pol.bidId();
        assertGt(pol.addBid(), 0);
        assertEq(pol.bidCount(), 2);
        assertTrue(pol.bidId() != first);
        assertLt(IERC20x(WOKB).balanceOf(address(pol)), 1e6); // no idle OKB
        pol.harvest(); // collects both ranges
    }

    function test_fixesGriefedPrice() public {
        pool.initialize(sqrtP0 * 10); // attacker opens at 100x price, no liquidity
        pol.bootstrap();
        (uint160 s,,,,,,) = pool.slot0();
        assertEq(s, sqrtP0);
    }

    function test_refusesPoolWithForeignLiquidity() public {
        pool.initialize(sqrtP0 * 10);
        cargo.mint(address(this), 1e18);
        IWETH9(WOKB).deposit{value: 1 ether}();
        cargo.approve(NPM, type(uint256).max);
        IERC20x(WOKB).approve(NPM, type(uint256).max);
        (address t0, address t1) = address(cargo) < WOKB ? (address(cargo), WOKB) : (WOKB, address(cargo));
        int24 sp = 200;
        int24 up = (887272 / sp) * sp;
        IV3NPM(NPM).mint(IV3NPM.MintParams(t0, t1, FEE, -up, up, 1e18, 1e18, 0, 0, address(this), block.timestamp));
        vm.expectRevert(CargoPol.PoolTaken.selector);
        pol.bootstrap();
    }
}
