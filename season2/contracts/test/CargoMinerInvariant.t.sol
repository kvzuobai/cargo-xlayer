// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// forge test --match-contract CargoMinerInvariant -vv   (no fork). Random stake/move/claim/unstake/warp sequences;
// power bookkeeping and CARGO supply must hold after every call.

import "forge-std/Test.sol";
import "../src/CargoToken.sol";
import "../src/CargoMiner.sol";
import {MockDock, MockCircuit, MockFactory} from "./CargoMiner.t.sol";

contract MinerHandler is Test {
    CargoMiner public miner;
    CargoToken public cargo;
    MockCircuit public s1;
    address[3] public actors = [makeAddr("a0"), makeAddr("a1"), makeAddr("a2")];
    uint256[] public live; // loaded rig ids
    uint256 public livePower;
    uint256 public burned;
    uint256 public moves;
    uint256 public fails;
    bytes4 public lastErr;
    uint256 nextId = 1;

    constructor(CargoMiner m, CargoToken c, MockCircuit s) {
        (miner, cargo, s1) = (m, c, s);
        for (uint256 i; i < 3; i++) {
            vm.deal(actors[i], 1_000 ether);
            vm.prank(actors[i]);
            cargo.approve(address(miner), type(uint256).max);
        }
    }

    function liveCount() external view returns (uint256) {
        return live.length;
    }

    function stake(uint256 a, uint256 nands, uint256 berth) external {
        address who = actors[a % 3];
        nands = bound(nands, 1, 40); // <= 0.08 OKB: stays under the 1 OKB wallet cap for a while
        uint256 id = nextId++;
        s1.make(who, id, nands);
        uint256 fee = miner.dockFeeFor(address(s1), id);
        vm.prank(who);
        try miner.stake{value: fee}(address(s1), id, uint8(berth % 25)) returns (uint256 r) {
            live.push(r);
            livePower += nands * 0.002 ether;
        } catch {}
    }

    function move(uint256 i, uint256 to) external {
        if (live.length == 0) return;
        uint256 r = live[i % live.length];
        (address owner,,,,,,,,,,,) = miner.rigs(r);
        if (to & 32 != 0) vm.warp(block.timestamp + 2 hours); // half the calls are past the cooldown
        uint256 fee = miner.moveFee(r, uint8(to % 25));
        uint256 s0 = cargo.totalSupply();
        uint256 m0 = miner.totalMinted();
        vm.prank(owner);
        try miner.move(r, uint8(to % 25)) {
            burned += fee;
            moves++;
            assertEq(cargo.totalSupply(), s0 + (miner.totalMinted() - m0) - fee, "move burns exactly moveFee");
        } catch (bytes memory e) {
            lastErr = bytes4(e);
            fails++;
        }
    }

    function claim(uint256 i) external {
        if (live.length == 0) return;
        uint256 r = live[i % live.length];
        (address owner,,,,,,,,,,,) = miner.rigs(r);
        uint256[] memory rs = new uint256[](1);
        rs[0] = r;
        vm.prank(owner);
        miner.claim(rs);
    }

    function unstake(uint256 i) external {
        if (live.length == 0) return;
        uint256 k = i % live.length;
        uint256 r = live[k];
        (address owner,,,,,,, uint256 power,,,,) = miner.rigs(r);
        vm.prank(owner);
        miner.unstake(r);
        livePower -= power;
        live[k] = live[live.length - 1];
        live.pop();
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 6 hours));
    }
}

/// forge-config: default.invariant.depth = 100
contract CargoMinerInvariant is Test {
    CargoMiner miner;
    CargoToken cargo;
    MinerHandler h;

    function setUp() public {
        cargo = new CargoToken();
        MockDock dock = new MockDock();
        MockFactory factory = new MockFactory();
        MockCircuit s1 = new MockCircuit(0.002 ether);
        dock.add(address(s1), 0.002 ether);
        factory.push(address(0xdead));
        miner = new CargoMiner(address(cargo), address(dock), address(factory), address(this), block.timestamp, 1 ether);
        cargo.setMinter(address(miner));
        h = new MinerHandler(miner, cargo, s1);
        targetContract(address(h));
    }

    function invariant_berthPowerSumsToTotal() public view {
        uint256 sum;
        for (uint256 b; b < 25; b++) {
            (uint128 p,,) = miner.berths(b);
            sum += p;
        }
        assertEq(sum, miner.totalPower(), "berths != totalPower");
        assertEq(miner.totalPower(), h.livePower(), "totalPower != loaded rigs");
    }

    function afterInvariant() public view {
        console.log("moves ok", h.moves(), "fails", h.fails());
        console.logBytes4(h.lastErr());
    }

    function invariant_supplyWithinEmission() public view {
        assertLe(miner.totalMinted(), miner.emittedUntil(block.timestamp) * 25 / 29, "minted above berth schedule");
        assertEq(cargo.totalSupply(), miner.totalMinted() - h.burned(), "supply != minted - move burns");
    }
}
