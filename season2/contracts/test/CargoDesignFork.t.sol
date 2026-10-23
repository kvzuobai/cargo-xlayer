// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// forge test --match-contract CargoDesignFork --fork-url https://rpc.xlayer.tech -vv
// Real TapeOut eval on X Layer: a Cargo season CPU, reference XOR (5 NAND) vs 4-NAND XOR, and 8-input parity gas.

import "forge-std/Test.sol";
import {CargoDock} from "../src/CargoDock.sol";
import {CargoDesign} from "../src/CargoDesign.sol";

interface IFCpu {
    function tapeout(bytes calldata, uint32, uint32) external payable;
    function TAPEOUT_FEE() external view returns (uint256);
    function nextId() external view returns (uint256);
    function transistorsContract() external view returns (address);
    function eval(uint256, bytes calldata) external view returns (bytes memory);
}

interface IFTr {
    function mintPrice() external view returns (uint256);
    function protocolFee() external view returns (uint256);
    function mint(uint256, uint256) external payable;
}

interface IFFactory {
    function deployFee() external view returns (uint256);
}

contract CargoDesignForkTest is Test {
    address constant FACTORY = 0x1f09DAeFA827f02CBb40967cc91b259763760761;
    CargoDock dock;
    CargoDesign d;
    IFCpu cpu;
    address user = makeAddr("user");

    function nand(uint24 a, uint24 b) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0), a, b);
    }

    function setUp() public {
        dock = new CargoDock(FACTORY, address(this), address(this));
        dock.setSinks(address(1), address(2), address(3), address(4));
        cpu = IFCpu(dock.openSeason{value: IFFactory(FACTORY).deployFee()}("Cargo T", "CGT", "t", 0.002 ether, 2_000_000));
        d = new CargoDesign(address(dock), address(this));
        vm.deal(user, 100 ether);
        IFTr tr = IFTr(cpu.transistorsContract());
        uint256 v = tr.mintPrice() * 200 + tr.protocolFee();
        vm.prank(user);
        tr.mint{value: v}(0, 200);
    }

    function _tape(bytes memory net, uint32 nIn, uint32 nOut) internal returns (uint256 id) {
        uint256 before = cpu.nextId();
        uint256 fee = cpu.TAPEOUT_FEE();
        vm.prank(user);
        cpu.tapeout{value: fee}(net, nIn, nOut);
        id = cpu.nextId(); // last id issued
        assertGt(id, before);
    }

    function test_realEvalXor() public {
        uint256 ref = _tape(bytes.concat(nand(2, 2), nand(3, 3), nand(2, 5), nand(4, 3), nand(6, 7)), 2, 1);
        uint256 eff = _tape(bytes.concat(nand(2, 3), nand(2, 4), nand(3, 4), nand(5, 6)), 2, 1);
        uint256 bad = _tape(bytes.concat(nand(2, 3), nand(4, 4)), 2, 1); // AND
        emit log_named_bytes("eval(ref, 01)", cpu.eval(ref, hex"01"));
        uint256 j = d.queueJob("XOR", address(cpu), ref);
        assertEq(d.expectedOf(j), hex"00010100");
        vm.warp(block.timestamp + 48 hours);
        uint256 g = gasleft();
        uint256 u = d.certify(address(cpu), eff, j);
        emit log_named_uint("certify gas XOR (real eval)", g - gasleft());
        assertEq(u, 31_250);
        vm.expectRevert(abi.encodeWithSelector(CargoDesign.WrongOutput.selector, 1));
        d.certify(address(cpu), bad, j);
    }

    function test_realEvalParity6Gas() public {
        bytes memory net;
        uint24 acc = 2;
        uint24 next = 8;
        for (uint24 i = 1; i < 6; i++) {
            uint24 b = 2 + i;
            net = bytes.concat(net, nand(acc, b), nand(acc, next), nand(b, next), nand(next + 1, next + 2));
            acc = next + 3;
            next += 4;
        }
        uint256 ref = _tape(net, 6, 1);
        uint256 g = gasleft();
        uint256 j = d.queueJob("PARITY6", address(cpu), ref);
        emit log_named_uint("queueJob gas PARITY6 (real eval)", g - gasleft());
        uint256 c = _tape(net, 6, 1);
        vm.warp(block.timestamp + 48 hours);
        g = gasleft();
        d.certify(address(cpu), c, j);
        emit log_named_uint("certify gas PARITY6 (real eval)", g - gasleft());
    }
}
