// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// forge test --match-contract CargoDockFork --fork-url https://rpc.xlayer.tech -vv
// Proves a contract can be the creator of a TapeOut CPU on X Layer and pull mint OKB.

import "forge-std/Test.sol";

interface IFactory {
    function createCPU(string calldata, string calldata, string calldata, uint256 supplyCap, uint256 mintPrice) external payable;
    function deployFee() external view returns (uint256);
    function cpuCount() external view returns (uint256);
    function cpuAt(uint256) external view returns (address);
    function isCPU(address) external view returns (bool);
}

interface ICircuits {
    function transistorsContract() external view returns (address);
    function tapeout(bytes calldata, uint32, uint32) external payable;
    function TAPEOUT_FEE() external view returns (uint256);
    function nextId() external view returns (uint256);
    function ownerOf(uint256) external view returns (address);
    function circuitInfo(uint256) external view returns (uint256, uint256, uint256, uint256);
    function eval(uint256, bytes calldata) external view returns (bytes memory);
}

interface ITransistors {
    function mint(uint256, uint256) external payable;
    function mintPrice() external view returns (uint256);
    function supplyCap() external view returns (uint256);
    function minted() external view returns (uint256);
    function protocolFee() external view returns (uint256);
    function creator() external view returns (address);
    function owed(address) external view returns (uint256);
    function withdraw() external;
    function balanceOf(address, uint256) external view returns (uint256);
}

/// Stand-in for CargoDock: creates the CPU, so it is `creator` and receives mint OKB.
contract DockProbe {
    IFactory constant F = IFactory(0x1f09DAeFA827f02CBb40967cc91b259763760761);
    address public cpu;

    function open(uint256 price, uint256 cap) external payable {
        F.createCPU{value: msg.value}("Cargo S1", "CGO1", "Cargo season 1", cap, price);
        cpu = F.cpuAt(F.cpuCount() - 1);
    }

    function pull() external {
        ITransistors(ICircuits(cpu).transistorsContract()).withdraw();
    }

    receive() external payable {}
}

contract CargoDockForkTest is Test {
    IFactory constant F = IFactory(0x1f09DAeFA827f02CBb40967cc91b259763760761);
    uint256 constant PRICE = 0.002 ether;
    uint256 constant CAP = 2_000_000;

    DockProbe dock;
    ICircuits cpu;
    ITransistors tr;
    address user = makeAddr("user");

    function setUp() public {
        dock = new DockProbe();
        dock.open{value: F.deployFee()}(PRICE, CAP);
        cpu = ICircuits(dock.cpu());
        tr = ITransistors(cpu.transistorsContract());
        vm.deal(user, 10 ether);
    }

    function test_creatorIsContract() public view {
        assertTrue(F.isCPU(address(cpu)));
        assertEq(tr.creator(), address(dock));
        assertEq(tr.mintPrice(), PRICE);
        assertEq(tr.supplyCap(), CAP);
        console.log("cpu", address(cpu), "transistors", address(tr));
        console.log("protocolFee", tr.protocolFee(), "tapeoutFee", cpu.TAPEOUT_FEE());
    }

    function test_mintTapeoutWithdraw() public {
        uint256 qty = 10;
        uint256 fee = tr.protocolFee();
        vm.prank(user);
        tr.mint{value: PRICE * qty + fee}(0, qty); // NAND
        assertEq(tr.balanceOf(user, 0), qty);
        uint256 owed = tr.owed(address(dock));
        console.log("owed to dock", owed);

        // NOT gate: 1 input (signal 2), NAND(2,2)
        bytes memory net = abi.encodePacked(uint8(0), uint24(2), uint24(2));
        uint256 id = cpu.nextId();
        uint256 tf = cpu.TAPEOUT_FEE();
        vm.prank(user);
        cpu.tapeout{value: tf}(net, 1, 1);
        uint256 newId = cpu.nextId() > id ? cpu.nextId() - 1 : id;
        if (newId == 0) newId = 1;
        assertEq(cpu.ownerOf(newId), user);
        (uint256 a, uint256 b, uint256 c, uint256 d) = cpu.circuitInfo(newId);
        console.log("circuitInfo", a, b);
        console.log("            ", c, d);
        console.log("NAND left", tr.balanceOf(user, 0));
        assertEq(cpu.eval(newId, hex"00")[0], bytes1(0x01));

        uint256 before = address(dock).balance;
        dock.pull();
        console.log("dock received", address(dock).balance - before);
        assertEq(address(dock).balance - before, owed);
    }
}

import {CargoDock} from "../src/CargoDock.sol";

contract Sink {
    uint256 public got;
    receive() external payable { got += msg.value; }
}

contract CargoDockSeasonForkTest is Test {
    address constant FACTORY = 0x1f09DAeFA827f02CBb40967cc91b259763760761;
    CargoDock dock;
    Sink cargoPol = new Sink();
    Sink bemPol = new Sink();
    Sink reserve = new Sink();
    Sink burner = new Sink();
    Sink team = new Sink();
    address user = makeAddr("user");

    function setUp() public {
        dock = new CargoDock(FACTORY, address(team), address(this));
        dock.setSinks(address(cargoPol), address(bemPol), address(reserve), address(burner));
        vm.deal(user, 100 ether);
    }

    function _open(uint256 price) internal returns (address) {
        return dock.openSeason{value: IFactory(FACTORY).deployFee()}("Cargo S", "CGO", "story", price, 2_000_000);
    }

    function _mint(address cpu, uint256 qty) internal {
        ITransistors tr = ITransistors(ICircuits(cpu).transistorsContract());
        uint256 p = tr.mintPrice();
        uint256 f = tr.protocolFee();
        vm.prank(user);
        tr.mint{value: p * qty + f}(0, qty);
    }

    function test_sweepSplitsSeason0() public {
        address cpu = _open(0.002 ether);
        assertTrue(dock.isCargoCpu(cpu));
        _mint(cpu, 1000); // 2 OKB
        assertEq(dock.sweep(0), 2 ether);
        assertEq(team.got(), 0.2 ether);
        assertEq(reserve.got(), 0.2 ether);
        assertEq(bemPol.got(), 0.7 ether);
        assertEq(cargoPol.got(), 0.9 ether);
        assertEq(address(dock).balance, 0);
        assertEq(dock.sweep(0), 0);
    }

    function test_seasonRules() public {
        _open(0.002 ether);
        uint256 fee = IFactory(FACTORY).deployFee();
        vm.expectRevert(CargoDock.TooSoon.selector);
        dock.openSeason{value: fee}("Cargo S", "CGO", "story", 0.0025 ether, 2_000_000);
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(CargoDock.PriceTooLow.selector);
        dock.openSeason{value: fee}("Cargo S", "CGO", "story", 0.00249 ether, 2_000_000);
        address cpu2 = _open(0.0025 ether);
        assertEq(dock.seasonCount(), 2);
        _mint(cpu2, 400); // 1 OKB, BEM share 40%
        dock.sweep(1);
        assertEq(bemPol.got(), 0.4 ether);
        assertEq(cargoPol.got(), 0.4 ether);
        assertEq(dock.bemBps(10), 5_000);
    }

    function test_dockFeeSplit() public {
        vm.prank(user);
        dock.payDockFee{value: 1 ether}();
        assertEq(burner.got(), 0.45 ether);
        assertEq(bemPol.got(), 0.45 ether);
        assertEq(team.got(), 0.1 ether);
    }

    function test_onlyOwnerAndSinksOnce() public {
        vm.prank(user);
        vm.expectRevert(CargoDock.NotOwner.selector);
        dock.openSeason("a", "b", "c", 1, 1);
        vm.expectRevert(CargoDock.AlreadySet.selector);
        dock.setSinks(user, user, user, user);
    }

    function test_refusesStrayOkb() public {
        vm.prank(user);
        (bool ok,) = address(dock).call{value: 1 ether}("");
        assertFalse(ok);
    }
}
