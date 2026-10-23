// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// forge test --match-contract CargoCore -vv   (no fork needed)

import "forge-std/Test.sol";
import "../src/CargoToken.sol";
import "../src/CargoReserve.sol";

contract MinerStub {
    uint256 public unclaimed;

    function set(uint256 u) external {
        unclaimed = u;
    }
}

contract CargoCoreTest is Test {
    MinerStub minerStub = new MinerStub();
    CargoToken cargo;
    CargoReserve res;
    address miner = makeAddr("miner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        cargo = new CargoToken();
        cargo.setMinter(miner);
        res = new CargoReserve(address(cargo), address(minerStub));
    }

    // ---- token ----
    function test_minterSetOnce() public {
        vm.expectRevert(CargoToken.NotAllowed.selector);
        cargo.setMinter(alice);
    }

    function test_onlyMinterMints() public {
        vm.expectRevert(CargoToken.NotAllowed.selector);
        vm.prank(alice);
        cargo.mint(alice, 1);
    }

    function test_capCountsBurned() public {
        vm.startPrank(miner);
        cargo.mint(alice, 10_000_000e18);
        vm.expectRevert(CargoToken.CapExceeded.selector);
        cargo.mint(alice, 1);
        vm.stopPrank();
        vm.prank(alice);
        cargo.burn(1e18);
        vm.prank(miner);
        vm.expectRevert(CargoToken.CapExceeded.selector); // burned supply is gone for good
        cargo.mint(alice, 1);
        assertEq(cargo.totalBurned(), 1e18);
    }

    function test_burnFromNeedsAllowance() public {
        vm.prank(miner);
        cargo.mint(alice, 10e18);
        vm.expectRevert();
        vm.prank(bob);
        cargo.burnFrom(alice, 1e18);
    }

    // ---- reserve ----
    function _fund(uint256 okb, uint256 aliceCargo, uint256 bobCargo) internal {
        vm.deal(address(this), okb);
        (bool ok,) = address(res).call{value: okb}("");
        assertTrue(ok);
        vm.startPrank(miner);
        cargo.mint(alice, aliceCargo);
        cargo.mint(bob, bobCargo);
        vm.stopPrank();
    }

    function test_redeemProRataMinusFee() public {
        _fund(100 ether, 250e18, 750e18); // floor 0.1 OKB / CARGO
        assertEq(res.floorPerCargo(), 0.1 ether);
        vm.startPrank(alice);
        cargo.approve(address(res), type(uint256).max);
        uint256 okb = res.redeem(100e18);
        vm.stopPrank();
        assertEq(okb, 9.9 ether); // 10 OKB - 1%
        assertEq(cargo.totalSupply(), 900e18);
        assertEq(res.totalOwed(), 9.9 ether);
        // floor for others does not drop: fee stays in the reserve
        assertGe(res.floorPerCargo(), 0.1 ether);
    }

    function test_cooldown() public {
        _fund(10 ether, 100e18, 0);
        vm.startPrank(alice);
        cargo.approve(address(res), type(uint256).max);
        res.redeem(50e18);
        vm.expectRevert(CargoReserve.NotReady.selector);
        res.claim();
        vm.warp(block.timestamp + 24 hours);
        uint256 b = alice.balance;
        res.claim();
        assertEq(alice.balance - b, 4.95 ether);
        assertEq(res.totalOwed(), 0);
        assertEq(res.pendingCount(alice), 0);
        vm.stopPrank();
    }

    function test_pendingNotDoubleCounted() public {
        _fund(10 ether, 100e18, 100e18);
        vm.prank(alice);
        cargo.approve(address(res), type(uint256).max);
        vm.prank(alice);
        res.redeem(100e18); // 4.95 owed, 5.05 free, 100 supply left
        vm.prank(bob);
        cargo.approve(address(res), type(uint256).max);
        vm.prank(bob);
        uint256 okb = res.redeem(100e18);
        assertEq(okb, 5.05 ether * 99 / 100);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        res.claim();
        vm.prank(bob);
        res.claim();
        assertEq(address(res).balance, 5.05 ether - okb); // only fees left
    }

    // CARGO earned but not claimed counts as supply: the first claimer gets only its own share
    function test_unclaimedCountsAsSupply() public {
        _fund(100 ether, 100e18, 0);
        minerStub.set(300e18); // others' unclaimed rewards
        assertEq(res.floorPerCargo(), 0.25 ether);
        vm.startPrank(alice);
        cargo.approve(address(res), type(uint256).max);
        assertEq(res.redeem(100e18), 24.75 ether); // 25 OKB - 1%, not 99
        vm.stopPrank();
    }

    // pro-rata redeem never lowers the floor of the remaining holders
    function testFuzz_redeemNeverLowersFloor(uint96 okb, uint96 a, uint96 r) public {
        okb = uint96(bound(okb, 1e9, type(uint96).max));
        a = uint96(bound(a, 1e9, 9_000_000e18)); // + bob's 1 CARGO stays under the 10M cap
        r = uint96(bound(r, 1, a - 1));
        _fund(okb, a, 1e18);
        uint256 before = res.floorPerCargo();
        vm.startPrank(alice);
        cargo.approve(address(res), type(uint256).max);
        if (res.quote(r) == 0) return;
        res.redeem(r);
        vm.stopPrank();
        assertGe(res.floorPerCargo(), before);
    }

    function testFuzz_reserveSolvent(uint96 okb, uint96 a, uint96 r) public {
        vm.assume(okb > 0);
        a = uint96(bound(a, 1, 10_000_000e18));
        r = uint96(bound(r, 1, a));
        _fund(okb, a, 0);
        vm.startPrank(alice);
        cargo.approve(address(res), type(uint256).max);
        if (res.quote(r) == 0) return;
        res.redeem(r);
        vm.stopPrank();
        assertLe(res.totalOwed(), address(res).balance);
    }
}
