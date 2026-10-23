// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// forge test --match-contract CargoE2EFork --fork-url https://rpc.xlayer.tech -vv
// Whole Cargo system as DeployCargo wires it, on real TapeOut + Uniswap v3 (X Layer):
// mint -> sweep -> bootstrap -> stake -> claim -> sell into bid -> harvest/burn -> BEM POL -> redeem -> season 2.

import "forge-std/Test.sol";
import {DeployCargo} from "../script/DeployCargo.s.sol";
import {CargoPol} from "../src/CargoPol.sol";
import {IV3Router, IWETH9} from "../src/UniV3Lib.sol";

interface ICpuE {
    function transistorsContract() external view returns (address);
    function tapeout(bytes calldata, uint32, uint32) external payable;
    function TAPEOUT_FEE() external view returns (uint256);
    function nextId() external view returns (uint256);
    function ownerOf(uint256) external view returns (address);
    function setApprovalForAll(address, bool) external;
}

interface ITrE {
    function mint(uint256, uint256) external payable;
    function protocolFee() external view returns (uint256);
}

interface IERC20e {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

contract CargoE2EForkTest is Test {
    address constant FACTORY = 0x1f09DAeFA827f02CBb40967cc91b259763760761;
    address constant ROUTER = 0x4f0C28f5926AFDA16bf2506D5D9e57Ea190f9bcA;
    address constant WOKB = 0xe538905cf8410324e03A5A23C1c177a474D59b2b;
    address constant BEM = 0x60e62Efa9405d6873C5deaBD4E6CC91c25363952;
    uint24 constant FEE = 10_000;

    DeployCargo d;
    DeployCargo.Cargo c;
    address team = makeAddr("team");
    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        d = new DeployCargo();
        c = d.deploy{value: 1 ether}(address(d), team, owner, 0);
        vm.prank(owner);
        c.dock.acceptOwner();
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    // ---------- helpers ----------

    function _mint(address u, address cpu, uint256 price, uint256 nand) internal {
        ITrE tr = ITrE(ICpuE(cpu).transistorsContract());
        vm.startPrank(u);
        tr.mint{value: price * nand + tr.protocolFee()}(0, nand);
        ICpuE(cpu).setApprovalForAll(address(c.miner), true);
        vm.stopPrank();
    }

    // n chained NAND gates (all inputs = wire 2): n transistors
    function _tapeout(address u, address cpu, uint256 n) internal returns (uint256 id) {
        bytes memory net;
        for (uint256 i; i < n; i++) net = abi.encodePacked(net, uint8(0), uint24(2), uint24(2));
        uint256 fee = ICpuE(cpu).TAPEOUT_FEE();
        vm.prank(u);
        ICpuE(cpu).tapeout{value: fee}(net, 1, 1);
        id = ICpuE(cpu).nextId();
    }

    function _stake(address u, address cpu, uint256 id, uint8 tile) internal returns (uint256 r) {
        uint256 fee = c.miner.dockFeeFor(cpu, id);
        vm.prank(u);
        r = c.miner.stake{value: fee}(cpu, id, tile);
    }

    function _claim(address u, uint256 r) internal {
        uint256[] memory rs = new uint256[](1);
        rs[0] = r;
        vm.prank(u);
        c.miner.claim(rs);
    }

    function _sell(address u, uint256 amt) internal returns (uint256) {
        vm.startPrank(u);
        c.token.approve(ROUTER, amt);
        uint256 out = IV3Router(ROUTER).exactInputSingle(
            IV3Router.ExactInputSingleParams(address(c.token), WOKB, FEE, u, amt, 0, 0)
        );
        vm.stopPrank();
        return out;
    }

    // ---------- the run ----------

    function test_fullLoop() public {
        assertEq(c.dock.owner(), owner);
        assertEq(address(c.miner.oracle()), address(c.burner));

        // 1. S1 mints, sweep: 10 team / 10 reserve / 35 BEM POL / 45 CARGO POL
        _mint(alice, c.cpu, 0.002 ether, 2_000);
        _mint(bob, c.cpu, 0.002 ether, 500);
        uint256 okb = c.dock.sweep(0);
        assertEq(okb, 2_500 * 0.002 ether);
        assertEq(team.balance, okb / 10);
        assertEq(address(c.reserve).balance, okb / 10);
        assertEq(address(c.bemPol).balance, okb * 35 / 100);
        assertEq(address(c.cargoPol).balance, okb * 45 / 100);

        // 2. pool opened at P0 in deploy (seed range); mint OKB joins the buy range, no CARGO needed
        (uint160 sp,,,,,,) = c.cargoPol.pool().slot0();
        assertEq(sp, d.sqrtP0(address(c.token)));
        c.cargoPol.addBid();
        assertEq(address(c.cargoPol).balance, 0);
        assertLt(IERC20e(WOKB).balanceOf(address(c.cargoPol)), 1e6);

        // 3. stake rigs: dock fee 45 burner / 45 BEM POL / 10 team
        uint256 ra = _stake(alice, c.cpu, _tapeout(alice, c.cpu, 1_500), 3);
        uint256 rb = _stake(bob, c.cpu, _tapeout(bob, c.cpu, 500), 3); // same tile: pro-rata 3:1
        uint256 fees = (1_500 + 500) * 0.002 ether * 5 / 100;
        assertEq(address(c.burner).balance, fees * 45 / 100);

        // 4. one day of emission: one berth share of 29 -> 5,000 / 29 = 172.4 CARGO, split 3:1
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1 days);
        _claim(alice, ra);
        _claim(bob, rb);
        assertApproxEqAbs(c.token.balanceOf(alice), uint256(5_000e18) * 3 / 4 / 29, 1e9);
        assertApproxEqAbs(c.token.balanceOf(bob), uint256(5_000e18) / 4 / 29, 1e9);

        // 5. alice sells into the protocol bid at ~P0 (0.00005 OKB)
        uint256 got = _sell(alice, 100e18);
        console.log("OKB for 100 CARGO", got);
        assertApproxEqRel(got, 100 * 0.00005 ether, 0.04e18); // 1% pool fee + impact on a 2.25 OKB bid

        // 6. harvest: seller's CARGO fee burned; burner spends dock-fee OKB on CARGO once TWAP caught up
        c.cargoPol.harvest();
        assertGt(c.token.totalBurned(), 0);
        vm.warp(block.timestamp + 1_000);
        vm.roll(block.number + 1_000);
        uint256 burned = c.burner.burn(0.001 ether);
        assertGt(burned, 0);
        console.log("burner CARGO for 0.001 OKB", burned);

        // 7. BEM POL: grow BEM pool history, then lock BEM-OKB liquidity
        _ageBemPool();
        uint128 liq = c.bemPol.add();
        assertGt(liq, 0);

        // 8. redeem pro-rata (floor >> P0 early: selling below it only hands value to the buyer); floor never drops
        uint256 floorBefore = c.reserve.floorPerCargo();
        uint256 q = c.reserve.quote(10e18);
        assertApproxEqAbs(q, c.reserve.freeOkb() * 10e18 / c.reserve.supply() * 99 / 100, 1e3);
        console.log("floor per CARGO", floorBefore);
        vm.startPrank(bob);
        c.token.approve(address(c.reserve), 10e18);
        c.reserve.redeem(10e18);
        vm.stopPrank();
        assertGe(c.reserve.floorPerCargo(), floorBefore); // redeem itself never lowers it
        vm.warp(block.timestamp + 1 days);
        uint256 before = bob.balance;
        vm.prank(bob);
        c.reserve.claim();
        assertEq(bob.balance - before, q);

        // 9. season 2 after 30 days at x1.25: stake burns 20% of rig value in CARGO (TWAP oracle)
        vm.warp(block.timestamp + 30 days);
        _keepTwapFresh();
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        address cpu2 = c.dock.openSeason{value: 0.0066 ether}("Cargo S2", "CGO2", "s2", 0.0025 ether, 2_000_000);
        _claim(alice, ra); // 30 more days on S1 rig
        _mint(alice, cpu2, 0.0025 ether, 10);
        uint256 id2 = _tapeout(alice, cpu2, 10);
        uint256 need = c.burner.cargoForOkb(10 * 0.0025 ether * 20 / 100);
        uint256 supplyBefore = c.token.totalSupply();
        uint256 fee2 = c.miner.dockFeeFor(cpu2, id2);
        vm.startPrank(alice);
        c.token.approve(address(c.miner), need);
        c.miner.stake{value: fee2}(cpu2, id2, 0);
        vm.stopPrank();
        assertEq(supplyBefore - c.token.totalSupply(), need);
        console.log("S2 rig CARGO burned", need);
    }

    function test_dockOwnerOnlyAndNoSecondWiring() public {
        vm.expectRevert();
        c.dock.openSeason{value: 0.0066 ether}("x", "x", "x", 0.01 ether, 1);
        vm.prank(owner);
        vm.expectRevert(); // sinks set once
        c.dock.setSinks(address(1), address(1), address(1), address(1));
        vm.expectRevert(); // minter set once
        c.token.setMinter(address(this));
        vm.expectRevert(); // oracle set once
        c.miner.setOracle(address(this));
    }

    function test_firstClaimerCannotTakeOthersShare() public {
        _mint(alice, c.cpu, 0.002 ether, 100);
        _mint(bob, c.cpu, 0.002 ether, 100);
        c.dock.sweep(0);
        uint256 ra = _stake(alice, c.cpu, _tapeout(alice, c.cpu, 100), 1);
        _stake(bob, c.cpu, _tapeout(bob, c.cpu, 100), 2); // same power, other tile, bob does not claim
        vm.warp(block.timestamp + 1 days);
        _claim(alice, ra);
        assertApproxEqAbs(c.miner.unclaimed(), uint256(5_000e18) / 29, 1e9);
        uint256 r = address(c.reserve).balance;
        vm.startPrank(alice);
        c.token.approve(address(c.reserve), type(uint256).max);
        uint256 got = c.reserve.redeem(c.token.balanceOf(alice));
        vm.stopPrank();
        assertApproxEqRel(got, r / 2 * 99 / 100, 1e12); // half, not all of it
    }

    function test_dockOwnerTwoStep() public {
        vm.prank(owner);
        c.dock.setOwner(address(0xBAD));
        assertEq(c.dock.owner(), owner); // typo does not take effect until accepted
        vm.prank(owner);
        c.dock.setOwner(alice);
        vm.prank(alice);
        c.dock.acceptOwner();
        assertEq(c.dock.owner(), alice);
    }

    function test_sqrtP0() public view {
        uint256 sp = d.sqrtP0(address(c.token));
        // price token1/token0 back from Q96
        uint256 p = sp * sp >> 96;
        if (address(c.token) < WOKB) assertApproxEqRel(p, (uint256(1) << 96) / 20_000, 1e12);
        else assertApproxEqRel(p, (uint256(1) << 96) * 20_000, 1e12);
    }

    // ---------- pool history ----------

    function _ageBemPool() internal {
        vm.deal(address(this), 10 ether);
        IWETH9(WOKB).deposit{value: 1 ether}();
        IERC20e(WOKB).approve(ROUTER, type(uint256).max);
        for (uint256 i; i < 16; i++) {
            vm.warp(block.timestamp + 60);
            vm.roll(block.number + 60);
            IV3Router(ROUTER).exactInputSingle(
                IV3Router.ExactInputSingleParams(WOKB, BEM, FEE, address(this), 0.01 ether, 0, 0)
            );
        }
    }

    // a tiny CARGO trade inside the TWAP window so the 15-min oracle has a recent observation
    function _keepTwapFresh() internal {
        _sell(bob, 1e18);
        vm.warp(block.timestamp + 1_000);
        vm.roll(block.number + 1_000);
        _sell(bob, 1e18);
    }
}
