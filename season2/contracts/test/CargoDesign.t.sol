// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import {CargoDesign} from "../src/CargoDesign.sol";

/// TapeOut-like circuits: NAND (op 0) / LATCH (op 1) / REF (op 2) netlists, eval() simulates NAND-only netlists.
contract EvalCpu {
    struct C { bytes net; uint32 nIn; uint32 nOut; uint32 nState; }
    mapping(uint256 => C) public cs;

    function set(uint256 id, bytes memory net, uint32 nIn, uint32 nOut, uint32 nState) external {
        cs[id] = C(net, nIn, nOut, nState);
    }

    function netlist(uint256 id) external view returns (bytes memory) {
        return cs[id].net;
    }

    function circuitInfo(uint256 id) external view returns (uint32, uint32, uint32, uint32) {
        C storage c = cs[id];
        return (c.nIn, c.nOut, c.nState, uint32(c.net.length / 7));
    }

    function eval(uint256 id, bytes calldata inp) external view returns (bytes memory out) {
        C storage c = cs[id];
        bytes memory n = c.net;
        uint256 g = n.length / 7;
        bool[] memory s = new bool[](2 + c.nIn + g);
        s[1] = true;
        for (uint256 i; i < c.nIn; i++) s[2 + i] = (uint8(inp[i >> 3]) >> (i & 7)) & 1 == 1;
        for (uint256 k; k < g; k++) {
            uint256 o = k * 7;
            uint256 a = (uint256(uint8(n[o + 1])) << 16) | (uint256(uint8(n[o + 2])) << 8) | uint256(uint8(n[o + 3]));
            uint256 b = (uint256(uint8(n[o + 4])) << 16) | (uint256(uint8(n[o + 5])) << 8) | uint256(uint8(n[o + 6]));
            s[2 + c.nIn + k] = !(s[a] && s[b]);
        }
        out = new bytes((c.nOut + 7) / 8 + 1); // one extra padding byte: the registry must ignore it
        uint256 first = s.length - c.nOut;
        for (uint256 i; i < c.nOut; i++) if (s[first + i]) out[i >> 3] |= bytes1(uint8(1 << (i & 7)));
        out[out.length - 1] = 0xff;
    }
}

contract SeasonDock {
    mapping(address => uint256) public seasonOf;

    function set(address cpu, uint256 s) external {
        seasonOf[cpu] = s;
    }
}

contract CargoDesignTest is Test {
    CargoDesign d;
    EvalCpu cpu;
    EvalCpu other;
    SeasonDock dock;
    address owner = makeAddr("owner");

    function nand(uint24 a, uint24 b) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0), a, b);
    }

    // signals: 0 = 0, 1 = 1, 2 = a, 3 = b, then one per gate
    function xor5() internal pure returns (bytes memory) { // reference: NOT a, NOT b, a.~b, ~a.b, OR
        return bytes.concat(nand(2, 2), nand(3, 3), nand(2, 5), nand(4, 3), nand(6, 7));
    }

    function xor4() internal pure returns (bytes memory) { // classic 4-NAND XOR
        return bytes.concat(nand(2, 3), nand(2, 4), nand(3, 4), nand(5, 6));
    }

    function setUp() public {
        cpu = new EvalCpu();
        other = new EvalCpu();
        dock = new SeasonDock();
        dock.set(address(cpu), 1);
        d = new CargoDesign(address(dock), owner);
        cpu.set(1, xor5(), 2, 1, 0); // reference
        cpu.set(2, xor4(), 2, 1, 0); // efficient
        vm.prank(owner);
        d.queueJob("XOR", address(cpu), 1);
    }

    function _ready() internal {
        vm.warp(block.timestamp + 48 hours);
    }

    function test_jobStoresTruthTable() public view {
        assertEq(d.expectedOf(0), hex"00010100"); // XOR of inputs 0..3
        (string memory name,,, uint256 nIn, uint256 nOut, uint256 k,,,,,) = d.job(0);
        assertEq(name, "XOR");
        assertEq(nIn, 2);
        assertEq(nOut, 1);
        assertEq(k, 5);
    }

    function test_timelockAndOwner() public {
        vm.expectRevert(CargoDesign.NotReady.selector);
        d.certify(address(cpu), 2, 0);
        vm.expectRevert(CargoDesign.NotOwner.selector);
        d.queueJob("X", address(cpu), 1);
        vm.expectRevert(CargoDesign.NotOwner.selector);
        d.retireJob(0);
        _ready();
        d.certify(address(cpu), 2, 0);
    }

    function test_bonusFollowsEfficiency() public {
        _ready();
        cpu.set(3, xor5(), 2, 1, 0);
        uint256 uEff = d.certify(address(cpu), 2, 0); // C = 4
        uint256 uRef = d.certify(address(cpu), 3, 0); // C = 5 = K
        assertEq(uRef, 25_000); // 0.5 K
        assertEq(uEff, 31_250); // 25/4 / 2
        uint256 price = 0.002 ether;
        assertEq(d.bonusPower(address(cpu), 2, 4 * price), price * 3125 / 1000);
        assertEq(d.bonusPower(address(cpu), 3, 5 * price), price * 25 / 10);
        assertEq(d.bonusPower(address(cpu), 9, 5 * price), 0); // not certified
    }

    function test_paddingAddsNoDesignPower() public {
        _ready();
        // 20 dummy gates before the real XOR: outputs are the last signal, so the function is unchanged
        bytes memory pad;
        for (uint256 i; i < 20; i++) pad = bytes.concat(pad, nand(2, 3));
        bytes memory net = bytes.concat(pad, nand(2, 3), nand(2, 24), nand(3, 24), nand(25, 26));
        cpu.set(4, net, 2, 1, 0);
        uint256 u = d.certify(address(cpu), 4, 0); // C = 24
        assertEq(u, 6_250); // floor: K/4 / 2
        assertLt(u, 25_000);
    }

    function test_bonusClampsHigh() public view {
        assertEq(d.bonusUnits(10, 1), 20_000); // K would be 100_000; capped at 2C = 20_000 (3x)
        assertEq(d.bonusUnits(5, 4), 31_250); // below the cap: unchanged
    }

    function test_wrongFunctionRejected() public {
        _ready();
        cpu.set(5, bytes.concat(nand(2, 3), nand(4, 4)), 2, 1, 0); // AND
        vm.expectRevert(abi.encodeWithSelector(CargoDesign.WrongOutput.selector, 1));
        d.certify(address(cpu), 5, 0);
        cpu.set(6, xor4(), 2, 2, 0); // shape mismatch
        vm.expectRevert(CargoDesign.BadCircuit.selector);
        d.certify(address(cpu), 6, 0);
    }

    function test_refLatchStateAndForeignRejected() public {
        _ready();
        cpu.set(7, abi.encodePacked(uint8(2), address(cpu), uint64(1), uint8(2), uint8(1), uint24(2), uint24(3)), 2, 1, 0);
        vm.expectRevert(CargoDesign.BadNetlist.selector);
        d.certify(address(cpu), 7, 0);
        cpu.set(8, bytes.concat(abi.encodePacked(uint8(1), uint24(2)), xor4()), 2, 1, 0);
        vm.expectRevert(CargoDesign.BadNetlist.selector);
        d.certify(address(cpu), 8, 0);
        cpu.set(9, xor4(), 2, 1, 1); // has state
        vm.expectRevert(CargoDesign.BadCircuit.selector);
        d.certify(address(cpu), 9, 0);
        other.set(2, xor4(), 2, 1, 0); // not a Cargo season CPU
        vm.expectRevert(CargoDesign.BadCircuit.selector);
        d.certify(address(other), 2, 0);
    }

    function test_recordAndNoRepeat() public {
        _ready();
        cpu.set(10, xor4(), 2, 1, 0);
        vm.expectEmit(true, false, false, true);
        emit CargoDesign.NewRecord(0, address(cpu), 2, 4);
        d.certify(address(cpu), 2, 0);
        d.certify(address(cpu), 10, 0); // same C: certified, record stays with the first
        (,,,,,,,, uint256 bestC, address bestCpu, uint256 bestId) = d.job(0);
        assertEq(bestC, 4);
        assertEq(bestCpu, address(cpu));
        assertEq(bestId, 2);
        vm.expectRevert(CargoDesign.NotBetter.selector);
        d.certify(address(cpu), 2, 0);
    }

    function test_retireBlocksNewOnly() public {
        _ready();
        d.certify(address(cpu), 2, 0);
        vm.prank(owner);
        d.retireJob(0);
        cpu.set(11, xor4(), 2, 1, 0);
        vm.expectRevert(CargoDesign.NotReady.selector);
        d.certify(address(cpu), 11, 0);
        assertGt(d.bonusPower(address(cpu), 2, 4), 0);
    }

    function test_twoStepOwner() public {
        address n = makeAddr("multisig");
        vm.prank(owner);
        d.setOwner(n);
        vm.prank(n);
        d.acceptOwner();
        assertEq(d.owner(), n);
    }

    function test_sixInputJob() public {
        // 6-input parity: chain of 5 XOR4 blocks (20 NAND), 64 vectors
        bytes memory net;
        uint24 acc = 2;
        uint24 next = 8;
        for (uint24 i = 1; i < 6; i++) {
            uint24 b = 2 + i;
            net = bytes.concat(net, nand(acc, b), nand(acc, next), nand(b, next), nand(next + 1, next + 2));
            acc = next + 3;
            next += 4;
        }
        cpu.set(20, net, 6, 1, 0);
        vm.prank(owner);
        uint256 j = d.queueJob("PARITY6", address(cpu), 20);
        _ready();
        cpu.set(21, net, 6, 1, 0);
        uint256 g = gasleft();
        d.certify(address(cpu), 21, j);
        emit log_named_uint("certify gas (6 inputs, 20 NAND, mock eval)", g - gasleft());
    }

    function test_workBoundRejectsBigCircuits() public {
        bytes memory net;
        for (uint256 i; i < 17; i++) net = bytes.concat(net, nand(2, 3)); // 256 vectors x 17 gates > 4096
        cpu.set(30, net, 8, 1, 0);
        vm.prank(owner);
        vm.expectRevert(CargoDesign.BadCircuit.selector);
        d.queueJob("BIG", address(cpu), 30);
    }
}
