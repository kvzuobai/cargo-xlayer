// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/CargoToken.sol";
import "../src/CargoMiner.sol";
import "../src/CargoDesign.sol";
import {MockDock, MockFactory} from "./CargoMiner.t.sol";
import {EvalCpu} from "./CargoDesign.t.sol";

contract EvalNft is EvalCpu {
    mapping(uint256 => address) public ownerOf;
    function mint(address to, uint256 id) external { ownerOf[id] = to; }
    function transferFrom(address f, address t, uint256 id) external {
        require(ownerOf[id] == f && (msg.sender == f || msg.sender == t), "auth");
        ownerOf[id] = t;
    }
}

// fake reference CPU: tiny circuitInfo, huge netlist, NOT truth table
contract FakeRef {
    uint256 public n;
    constructor(uint256 n_) { n = n_; }
    function circuitInfo(uint256) external pure returns (uint32, uint32, uint32, uint32) { return (1, 1, 0, 1); }
    function netlist(uint256) external view returns (bytes memory b) {
        b = new bytes(n * 7); // zero bytes = NAND(0,0) gates
    }
    function eval(uint256, bytes calldata inp) external pure returns (bytes memory o) {
        o = new bytes(1);
        o[0] = bytes1(uint8(inp[0]) & 1 == 1 ? 0 : 1);
    }
}

/// Real CargoDesign + CargoMiner together (engineer review 2026-10-24: H1, H2, M2).
contract CargoDesignMinerTest is Test {
    uint128 constant P = 0.002 ether;
    CargoToken cargo; MockDock dock; MockFactory factory; EvalNft cpu; CargoMiner miner; CargoDesign design;
    address founder = makeAddr("founder"); address alice = makeAddr("alice"); address bob = makeAddr("bob");

    function nand(uint24 a, uint24 b) internal pure returns (bytes memory) { return abi.encodePacked(uint8(0), a, b); }
    function xor4() internal pure returns (bytes memory) { return bytes.concat(nand(2, 3), nand(2, 4), nand(3, 4), nand(5, 6)); }
    function bloatedXor(uint256 pad) internal pure returns (bytes memory net) {
        for (uint256 i; i < pad; i++) net = bytes.concat(net, nand(2, 3));
        uint24 s = uint24(4 + pad); // first real gate signal
        net = bytes.concat(net, nand(2, 3), nand(2, s), nand(3, s), nand(s + 1, s + 2));
    }

    function setUp() public {
        cargo = new CargoToken(); dock = new MockDock(); factory = new MockFactory(); cpu = new EvalNft();
        dock.add(address(cpu), P);
        miner = new CargoMiner(address(cargo), address(dock), address(factory), founder, block.timestamp, 1 ether);
        design = new CargoDesign(address(dock), founder);
        miner.setDesign(address(design));
        cargo.setMinter(address(miner));
        vm.deal(alice, 100 ether); vm.deal(bob, 100 ether);
    }

    function _rig(uint256 r) internal view returns (uint256 p) { (,,,,,,, p,,,,) = miner.rigs(r); }

    // H1: a short design against a weak (24-NAND) reference is capped at 3x its transistor value
    function test_leverageCappedAtThreeX() public {
        cpu.set(1, bloatedXor(20), 2, 1, 0); // reference with 24 NAND (owner-chosen, e.g. naive)
        vm.prank(founder); design.queueJob("XOR", address(cpu), 1);
        vm.warp(block.timestamp + 48 hours);
        cpu.set(2, xor4(), 2, 1, 0); cpu.mint(alice, 2);
        design.certify(address(cpu), 2, 0);
        uint256 fee = miner.dockFeeFor(address(cpu), 2);
        vm.prank(alice); uint256 r = miner.stake{value: fee}(address(cpu), 2, 0);
        uint256 base = 4 * uint256(P);
        emit log_named_uint("base power (wei)", base);
        emit log_named_uint("rig power  (wei)", _rig(r));
        emit log_named_uint("leverage x100", _rig(r) * 100 / base);
        assertEq(_rig(r), 3 * base); // capped: B <= 2C
    }

    // H2: a job's reference must be a Cargo season circuit; a fake contract cannot set K or the truth table
    function test_fakeRefRejected() public {
        FakeRef f = new FakeRef(400);
        vm.prank(founder);
        vm.expectRevert(CargoDesign.BadJob.selector);
        design.queueJob("EVIL", address(f), 1);
    }

    // 3. certify after load changes nothing for the staked rig; consistency of totals through buy + unstake
    function test_stakeBuyUnstakeConsistency() public {
        cpu.set(1, bloatedXor(1), 2, 1, 0);
        vm.prank(founder); design.queueJob("XOR", address(cpu), 1);
        vm.warp(block.timestamp + 48 hours);
        cpu.set(2, xor4(), 2, 1, 0); cpu.mint(alice, 2);
        uint256 fee = miner.dockFeeFor(address(cpu), 2);
        vm.prank(alice); uint256 r = miner.stake{value: fee}(address(cpu), 2, 3); // not certified yet
        assertEq(_rig(r), 4 * uint256(P));
        design.certify(address(cpu), 2, 0); // certify while staked
        assertEq(_rig(r), 4 * uint256(P)); // frozen
        vm.prank(alice); miner.unstake(r);
        assertEq(miner.totalPower(), 0); assertEq(miner.s1PowerOf(alice), 0);
        vm.prank(alice); r = miner.stake{value: fee}(address(cpu), 2, 3);
        uint256 p = _rig(r);
        assertGt(p, 4 * uint256(P));
        assertEq(miner.s1PowerOf(alice), p); assertEq(miner.totalPower(), p);
        vm.prank(alice); miner.list(r, 1 ether);
        vm.prank(bob); miner.buy{value: 1 ether}(r, 3);
        assertEq(miner.s1PowerOf(alice), 0); assertEq(miner.s1PowerOf(bob), p);
        vm.prank(bob); miner.unstake(r);
        assertEq(miner.totalPower(), 0); assertEq(miner.s1PowerOf(bob), 0);
        (uint128 bp,,) = miner.berths(3); assertEq(bp, 0);
    }
}
