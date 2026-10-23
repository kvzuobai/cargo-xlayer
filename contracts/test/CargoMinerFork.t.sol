// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// forge test --match-contract CargoMinerFork --fork-url https://rpc.xlayer.tech -vv
// Real TapeOut season CPU on X Layer: netlist parse, rig transfer, dock fee, and whether REF gates burn transistors.

import "forge-std/Test.sol";
import {CargoDock} from "../src/CargoDock.sol";
import {CargoToken} from "../src/CargoToken.sol";
import {CargoMiner} from "../src/CargoMiner.sol";

interface IFactoryF {
    function deployFee() external view returns (uint256);
    function createCPU(string calldata, string calldata, string calldata, uint256, uint256) external payable;
    function cpuCount() external view returns (uint256);
    function cpuAt(uint256) external view returns (address);
}

interface ICpuF {
    function transistorsContract() external view returns (address);
    function tapeout(bytes calldata, uint32, uint32) external payable;
    function TAPEOUT_FEE() external view returns (uint256);
    function nextId() external view returns (uint256);
    function ownerOf(uint256) external view returns (address);
    function circuitInfo(uint256) external view returns (uint256, uint256, uint256, uint256);
    function netlist(uint256) external view returns (bytes memory);
    function setApprovalForAll(address, bool) external;
}

interface ITrF {
    function mint(uint256, uint256) external payable;
    function mintPrice() external view returns (uint256);
    function protocolFee() external view returns (uint256);
    function balanceOf(address, uint256) external view returns (uint256);
}

contract SinkF {
    uint256 public got;
    receive() external payable { got += msg.value; }
}

contract CargoMinerForkTest is Test {
    address constant FACTORY = 0x1f09DAeFA827f02CBb40967cc91b259763760761;
    CargoDock dock;
    CargoToken cargo;
    CargoMiner miner;
    ICpuF cpu;
    ITrF tr;
    SinkF burner = new SinkF();
    SinkF bemPol = new SinkF();
    SinkF team = new SinkF();
    address user = makeAddr("user");

    function setUp() public {
        dock = new CargoDock(FACTORY, address(team), address(this));
        dock.setSinks(address(new SinkF()), address(bemPol), address(new SinkF()), address(burner));
        cpu = ICpuF(dock.openSeason{value: IFactoryF(FACTORY).deployFee()}("Cargo S1", "CGO1", "s1", 0.002 ether, 2_000_000));
        tr = ITrF(cpu.transistorsContract());
        cargo = new CargoToken();
        miner = new CargoMiner(address(cargo), address(dock), address(0), address(this), block.timestamp, 0);
        cargo.setMinter(address(miner));
        vm.deal(user, 100 ether);
        vm.startPrank(user);
        tr.mint{value: 0.002 ether * 100 + tr.protocolFee()}(0, 100); // NAND
        tr.mint{value: 0.002 ether * 10 + tr.protocolFee()}(1, 10); // LATCH
        cpu.setApprovalForAll(address(miner), true);
        vm.stopPrank();
    }

    function _tapeout(bytes memory net, uint32 nIn, uint32 nOut) internal returns (uint256 id) {
        uint256 fee = cpu.TAPEOUT_FEE();
        vm.prank(user);
        cpu.tapeout{value: fee}(net, nIn, nOut);
        id = cpu.nextId(); // TapeOut: nextId() = last id issued (ids start at 1)
        assertEq(cpu.ownerOf(id), user);
    }

    function test_netlistCountsAndStake() public {
        // NOT -> NAND(2,2), then a LATCH on it: 2 transistors
        bytes memory net = abi.encodePacked(uint8(0), uint24(2), uint24(2), uint8(1), uint24(3));
        uint256 nandBefore = tr.balanceOf(user, 0);
        uint256 id = _tapeout(net, 1, 1);
        assertEq(keccak256(cpu.netlist(id)), keccak256(net));
        (,,, uint256 gates) = cpu.circuitInfo(id);
        console.log("gateCount", gates, "NAND burned", nandBefore - tr.balanceOf(user, 0));
        (uint256 power, uint256 season) = miner.powerOf(address(cpu), id);
        assertEq(season, 0);
        assertEq(power, 2 * 0.002 ether);

        uint256 fee = miner.dockFeeFor(address(cpu), id);
        vm.prank(user);
        uint256 r = miner.stake{value: fee}(address(cpu), id, 7);
        assertEq(cpu.ownerOf(id), address(miner));
        assertEq(burner.got(), fee * 45 / 100);
        assertEq(bemPol.got(), fee * 45 / 100);

        vm.warp(block.timestamp + 1 days);
        uint256[] memory rs = new uint256[](1);
        rs[0] = r;
        vm.prank(user);
        miner.claim(rs);
        assertApproxEqAbs(cargo.balanceOf(user), uint256(5_000e18) / 29, 1e6);

        vm.prank(user);
        miner.unstake(r);
        assertEq(cpu.ownerOf(id), user);
    }

    /// Records what TapeOut does with REF: does the caller burn the sub-circuit's transistors again?
    function test_refBurn() public {
        uint256 a = _tapeout(abi.encodePacked(uint8(0), uint24(2), uint24(2)), 1, 1);
        uint256 nandBefore = tr.balanceOf(user, 0);
        bytes memory net = abi.encodePacked(uint8(2), address(cpu), uint64(a), uint8(1), uint8(1), uint24(2));
        uint256 b = _tapeout(net, 1, 1);
        (,,, uint256 gates) = cpu.circuitInfo(b);
        console.log("REF circuit gateCount", gates, "NAND burned by REF tapeout", nandBefore - tr.balanceOf(user, 0));
        (uint256 power,) = miner.powerOf(address(cpu), b);
        assertEq(power, 0); // we count only direct gates
    }

    /// v2 official CPU on real TapeOut: whitelist via factory index (48h), power = transistors x mintPrice x 50%,
    /// only berths 19-24, no Y30; an existing factory CPU's mintPrice is read on-chain at queue time.
    function test_officialCpuReal() public {
        IFactoryF f = IFactoryF(FACTORY);
        CargoToken c2 = new CargoToken();
        CargoMiner m = new CargoMiner(address(c2), address(dock), FACTORY, address(this), block.timestamp, 0);
        c2.setMinter(address(m));

        // existing CPUs: free-mint ones (mintPrice 0) are rejected; the first priced one is read on-chain
        uint256 i;
        for (; i < 50; i++) {
            address ci = f.cpuAt(i);
            if (ITrF(ICpuF(ci).transistorsContract()).mintPrice() > 0) break;
            vm.expectRevert(CargoMiner.BadCpu.selector);
            m.queueOfficial(ci, i);
        }
        require(i < 50, "no priced CPU in first 50");
        address cpuI = f.cpuAt(i);
        m.queueOfficial(cpuI, i);
        (uint128 refI,,) = m.officials(cpuI);
        assertEq(refI, ITrF(ICpuF(cpuI).transistorsContract()).mintPrice());
        console.log("first priced CPU index", i, "mintPrice", refI);

        // a fresh outside CPU (not a Cargo season) at 0.001 OKB per transistor
        address other = makeAddr("otherProject");
        vm.deal(other, 1 ether);
        vm.prank(other);
        f.createCPU{value: f.deployFee()}("Other", "OTH", "outside project", 1_000_000, 0.001 ether);
        uint256 idx = f.cpuCount() - 1;
        ICpuF ocpu = ICpuF(f.cpuAt(idx));
        ITrF otr = ITrF(ocpu.transistorsContract());
        vm.expectRevert(CargoMiner.BadCpu.selector);
        m.queueOfficial(address(ocpu), idx - 1); // wrong index
        vm.expectRevert(CargoMiner.BadCpu.selector);
        m.queueOfficial(address(cpu), 0); // Cargo season CPU
        m.queueOfficial(address(ocpu), idx);
        vm.expectRevert(CargoMiner.Timelocked.selector);
        m.addOfficial(address(ocpu));
        vm.warp(block.timestamp + 48 hours);
        m.addOfficial(address(ocpu));

        vm.startPrank(user);
        otr.mint{value: 0.001 ether * 10 + otr.protocolFee()}(0, 10);
        ocpu.tapeout{value: ocpu.TAPEOUT_FEE()}(abi.encodePacked(uint8(0), uint24(2), uint24(2)), 1, 1);
        uint256 id = ocpu.nextId();
        ocpu.setApprovalForAll(address(m), true);
        (uint256 power, uint256 season) = m.powerOf(address(ocpu), id);
        assertEq(power, 0.0005 ether); // 1 NAND x 0.001 x 50%
        assertEq(season, m.OFFICIAL());
        uint256 fee = m.dockFeeFor(address(ocpu), id);
        vm.expectRevert(CargoMiner.BadBerth.selector);
        m.stake{value: fee}(address(ocpu), id, 18);
        uint256 r = m.stake{value: fee}(address(ocpu), id, 19);
        vm.stopPrank();
        assertEq(ocpu.ownerOf(id), address(m));

        m.notifyOkb{value: 1 ether}(); // Y30: official gets none
        vm.warp(block.timestamp + 1 days);
        (uint256 pc, uint256 po) = m.pending(r);
        assertApproxEqAbs(pc, uint256(5_000e18) / 29, 1e6);
        assertEq(po, 0);
        vm.prank(user);
        m.unstake(r);
        assertEq(ocpu.ownerOf(id), user);
        assertApproxEqAbs(c2.balanceOf(user), uint256(5_000e18) / 29, 1e6);
    }
}
