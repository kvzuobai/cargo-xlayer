// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// forge test --match-contract CargoMinerTest -vv   (no fork needed). CargoMiner v2 (Voyage), spec docs/cargo-voyage-spec.md §11.

import "forge-std/Test.sol";
import "../src/CargoToken.sol";
import "../src/CargoMiner.sol";

contract MockDock {
    mapping(address => uint256) public seasonOf;
    uint128[] public prices;
    uint256 public fees;

    function add(address cpu, uint128 price) external {
        prices.push(price);
        seasonOf[cpu] = prices.length;
    }

    function seasons(uint256 i) external view returns (address, address, uint128, uint64, uint64) {
        return (address(0), address(0), prices[i], 0, 0);
    }

    function payDockFee() external payable {
        fees += msg.value;
    }
}

contract MockTransistors {
    uint256 public mintPrice;

    constructor(uint256 p) {
        mintPrice = p;
    }
}

contract MockCircuit {
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => bytes) internal nets;
    address public transistorsContract;

    constructor(uint256 price) {
        transistorsContract = address(new MockTransistors(price));
    }

    function make(address to, uint256 id, uint256 nands) external {
        ownerOf[id] = to;
        bytes memory n;
        for (uint256 i; i < nands; i++) n = abi.encodePacked(n, uint8(0), uint24(2), uint24(2));
        nets[id] = n;
    }

    function netlist(uint256 id) external view returns (bytes memory) {
        return nets[id];
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from && (msg.sender == from || msg.sender == to), "auth");
        ownerOf[id] = to;
    }
}

contract MockFactory {
    address[] public cpus;

    function push(address c) external returns (uint256) {
        cpus.push(c);
        return cpus.length - 1;
    }

    function cpuAt(uint256 i) external view returns (address) {
        return cpus[i];
    }
}

contract MockOracle {
    function cargoForOkb(uint256 okb) external pure returns (uint256) {
        return okb * 100; // 1 OKB = 100 CARGO
    }
}

contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public feeBps; // fee-on-transfer when > 0

    function setFee(uint256 f) external {
        feeBps = f;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a - a * feeBps / 10_000;
        return true;
    }
}

contract RevertingSeller {
    function stake(CargoMiner m, MockCircuit c, uint256 id) external payable returns (uint256) {
        return m.stake{value: msg.value}(address(c), id, 0);
    }

    function list(CargoMiner m, uint256 r, uint256 p) external {
        m.list(r, p);
    }

    receive() external payable {
        revert("no");
    }
}

contract CargoMinerTest is Test {
    uint128 constant P1 = 0.002 ether;
    uint256 constant DAY_SHARE = uint256(5_000e18) / 29; // one berth share per day
    CargoToken cargo;
    MockDock dock;
    MockFactory factory;
    MockCircuit s1;
    MockCircuit s2;
    MockCircuit off;
    CargoMiner miner;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address founder = makeAddr("founder");
    address bemPol = makeAddr("bemPol");
    address burner = makeAddr("burner");
    address reserve = makeAddr("reserve");
    address team = makeAddr("team");

    function setUp() public {
        cargo = new CargoToken();
        dock = new MockDock();
        factory = new MockFactory();
        s1 = new MockCircuit(P1);
        s2 = new MockCircuit(0.0025 ether);
        off = new MockCircuit(0.004 ether); // official CPU, ref price 0.004 -> 0.002 per transistor at 50%
        dock.add(address(s1), P1);
        dock.add(address(s2), 0.0025 ether);
        factory.push(address(0xdead));
        miner = new CargoMiner(address(cargo), address(dock), address(factory), founder, block.timestamp, 1 ether);
        cargo.setMinter(address(miner));
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
    }

    // ---------- helpers ----------

    function _stake(address who, MockCircuit c, uint256 id, uint256 nands, uint8 berth) internal returns (uint256) {
        c.make(who, id, nands);
        uint256 fee = miner.dockFeeFor(address(c), id);
        vm.prank(who);
        return miner.stake{value: fee}(address(c), id, berth);
    }

    function _claim(address who, uint256 r) internal {
        uint256[] memory rs = new uint256[](1);
        rs[0] = r;
        vm.prank(who);
        miner.claim(rs);
    }

    function _whitelist() internal {
        uint256 idx = factory.push(address(off));
        vm.prank(founder);
        miner.queueOfficial(address(off), idx);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(founder);
        miner.addOfficial(address(off));
    }

    /// Earn CARGO for `who` (1 day solo on berth 24) and approve the miner.
    function _earn(address who, uint256 id) internal returns (uint256 r) {
        r = _stake(who, s1, id, 10, 24);
        vm.warp(block.timestamp + 1 days);
        _claim(who, r);
        vm.prank(who);
        cargo.approve(address(miner), type(uint256).max);
    }

    function _wire() internal {
        miner.setSinks(bemPol, burner, reserve, team);
    }

    // ---------- netlist + load ----------

    function test_transistorCount() public view {
        bytes memory n = abi.encodePacked(uint8(0), uint24(2), uint24(2), uint8(1), uint24(3));
        n = abi.encodePacked(n, uint8(2), address(0xBEEF), uint64(7), uint8(2), uint8(1), uint24(2), uint24(3));
        assertEq(miner.transistorCount(n), 2);
    }

    function test_badNetlistReverts() public {
        vm.expectRevert(CargoMiner.BadNetlist.selector);
        miner.transistorCount(hex"05");
        vm.expectRevert(CargoMiner.BadNetlist.selector);
        miner.transistorCount(hex"000002");
    }

    function test_stakeChargesDockFee() public {
        s1.make(alice, 1, 100); // 0.2 OKB power
        (uint256 p,) = miner.powerOf(address(s1), 1);
        assertEq(p, 0.2 ether);
        vm.prank(alice);
        vm.expectRevert(CargoMiner.WrongFee.selector);
        miner.stake{value: 0.009 ether}(address(s1), 1, 0);
        vm.prank(alice);
        uint256 r = miner.stake{value: 0.01 ether}(address(s1), 1, 0);
        assertEq(dock.fees(), 0.01 ether);
        assertEq(s1.ownerOf(1), address(miner));
        assertEq(miner.ownerOf(r), alice);
        assertEq(miner.balanceOf(alice), 1);
    }

    function test_rejects() public {
        MockCircuit x = new MockCircuit(1);
        x.make(alice, 1, 5);
        vm.prank(alice);
        vm.expectRevert(CargoMiner.NotCargoCpu.selector); // not whitelisted
        miner.stake(address(x), 1, 0);
        s1.make(alice, 2, 0); // circuit without transistors
        vm.prank(alice);
        vm.expectRevert(CargoMiner.NoPower.selector);
        miner.stake(address(s1), 2, 0);
        s1.make(alice, 3, 1);
        vm.prank(alice);
        vm.expectRevert(CargoMiner.BadBerth.selector);
        miner.stake{value: 0.0001 ether}(address(s1), 3, 25);
    }

    // ---------- emission ----------

    function test_soloRigEarnsBerthShare() public {
        uint256 r = _stake(alice, s1, 1, 10, 3);
        vm.warp(block.timestamp + 1 days);
        _claim(alice, r);
        assertApproxEqAbs(cargo.balanceOf(alice), DAY_SHARE, 1e6);
        assertApproxEqAbs(miner.berthBudget(), uint256(5_000e18) / 288 / 29, 1e6);
    }

    function test_proRataInBerth() public {
        uint256 a = _stake(alice, s1, 1, 10, 0);
        uint256 b = _stake(bob, s1, 2, 30, 0);
        vm.warp(block.timestamp + 1 days);
        _claim(alice, a);
        _claim(bob, b);
        assertApproxEqAbs(cargo.balanceOf(alice), DAY_SHARE / 4, 1e6);
        assertApproxEqAbs(cargo.balanceOf(bob), DAY_SHARE * 3 / 4, 1e6);
    }

    function test_emptyBerthsMintNothing() public {
        vm.warp(block.timestamp + 10 days);
        assertEq(miner.unclaimed(), 0);
        uint256 r = _stake(alice, s1, 1, 10, 0);
        vm.warp(block.timestamp + 1 days);
        assertApproxEqAbs(miner.unclaimed(), DAY_SHARE, 1e6); // only berth 0, only since load
        _claim(alice, r);
        assertApproxEqAbs(miner.unclaimed(), 0, 1e6);
    }

    function test_lazyEqualsStepwise() public {
        uint256 a = _stake(alice, s1, 1, 10, 0);
        uint256 b = _stake(bob, s1, 2, 10, 1);
        for (uint256 i; i < 1000; i++) {
            vm.warp(block.timestamp + 5 minutes);
            _claim(alice, a);
        }
        _claim(bob, b);
        assertApproxEqAbs(cargo.balanceOf(alice), cargo.balanceOf(bob), 1e9);
    }

    function test_emissionCap() public view {
        assertEq(miner.emittedUntil(block.timestamp + 2_000 days), 10_000_000e18);
        assertEq(miner.emittedUntil(block.timestamp + 5_000 days), 10_000_000e18);
        assertEq(miner.emittedUntil(block.timestamp + 1 days), 5_000e18);
    }

    function testFuzz_mintedNeverAboveSchedule(uint8 n, uint32 dt) public {
        n = uint8(bound(n, 1, 25));
        for (uint256 i; i < n; i++) _stake(i % 2 == 0 ? alice : bob, s1, i + 1, 1, uint8(i));
        vm.warp(block.timestamp + bound(dt, 1, 3_000 days));
        for (uint256 i; i < n; i++) _claim(i % 2 == 0 ? alice : bob, i);
        assertLe(miner.totalMinted(), miner.emittedUntil(block.timestamp) * 25 / 29);
        assertLe(cargo.totalSupply(), 10_000_000e18);
    }

    function test_moveOncePerVoyage() public {
        uint256 r = _stake(alice, s1, 1, 10, 0);
        vm.prank(alice);
        vm.expectRevert(CargoMiner.MovedThisVoyage.selector);
        miner.move(r, 1);
        vm.warp(block.timestamp + 5 minutes);
        vm.prank(alice);
        miner.move(r, 1);
        assertGt(cargo.balanceOf(alice), 0);
        vm.prank(alice);
        vm.expectRevert(CargoMiner.MovedThisVoyage.selector);
        miner.move(r, 2);
        vm.prank(bob);
        vm.expectRevert(CargoMiner.NotOwner.selector);
        miner.move(r, 2);
    }

    function test_season2BurnsCargo() public {
        _earn(alice, 1);
        s2.make(alice, 1, 4); // 0.01 OKB power -> burn 0.002 OKB of CARGO = 0.2 CARGO
        uint256 fee = miner.dockFeeFor(address(s2), 1);
        vm.prank(alice);
        vm.expectRevert(CargoMiner.NoOracle.selector);
        miner.stake{value: fee}(address(s2), 1, 0);
        miner.setOracle(address(new MockOracle()));
        uint256 before = cargo.balanceOf(alice);
        vm.prank(alice);
        miner.stake{value: fee}(address(s2), 1, 0);
        assertEq(before - cargo.balanceOf(alice), 0.2e18);
    }

    function test_walletCapSeason1() public {
        _stake(alice, s1, 1, 400, 0);
        s1.make(alice, 2, 101);
        uint256 fee = miner.dockFeeFor(address(s1), 2);
        vm.prank(alice);
        vm.expectRevert(CargoMiner.WalletCap.selector);
        miner.stake{value: fee}(address(s1), 2, 0);
    }

    function test_unstakeReturnsCircuitNoRefund() public {
        uint256 r = _stake(alice, s1, 1, 10, 0);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        miner.unstake(r);
        assertEq(s1.ownerOf(1), alice);
        assertApproxEqAbs(cargo.balanceOf(alice), DAY_SHARE, 1e6);
        assertEq(miner.totalPower(), 0);
        assertEq(miner.s1PowerOf(alice), 0);
        assertEq(miner.balanceOf(alice), 0);
        vm.expectRevert(CargoMiner.NotOwner.selector);
        miner.ownerOf(r);
        vm.prank(alice);
        vm.expectRevert(CargoMiner.NotOwner.selector);
        miner.unstake(r);
    }

    // ---------- official CPUs ----------

    function test_officialWhitelistTimelock() public {
        uint256 idx = factory.push(address(off));
        vm.prank(alice);
        vm.expectRevert(CargoMiner.NotOwner.selector);
        miner.queueOfficial(address(off), idx);
        vm.startPrank(founder);
        vm.expectRevert(CargoMiner.BadCpu.selector); // wrong factory index
        miner.queueOfficial(address(off), 0);
        uint256 sIdx = factory.push(address(s1));
        vm.expectRevert(CargoMiner.BadCpu.selector); // Cargo season CPU cannot be official
        miner.queueOfficial(address(s1), sIdx);
        miner.queueOfficial(address(off), idx);
        vm.expectRevert(CargoMiner.Timelocked.selector);
        miner.addOfficial(address(off));
        vm.warp(block.timestamp + 48 hours);
        miner.addOfficial(address(off));
        vm.expectRevert(CargoMiner.BadCpu.selector); // review L2: no re-queue of an active CPU
        miner.queueOfficial(address(off), idx);
        vm.stopPrank();
        assertEq(miner.officialCount(), 1);
        off.make(alice, 1, 10);
        (uint256 p, uint256 season) = miner.powerOf(address(off), 1);
        assertEq(p, 10 * 0.002 ether); // 10 x 0.004 x 50%
        assertEq(season, miner.OFFICIAL());
    }

    /// Review M3: official circuits only in berths 19-24, so their CARGO share is <= 6/29 whatever Cargo rigs do.
    function test_officialOnlyInOfficialBerths() public {
        _whitelist();
        off.make(alice, 1, 10);
        vm.prank(alice);
        vm.expectRevert(CargoMiner.BadBerth.selector);
        miner.stake{value: 0.001 ether}(address(off), 1, 18);
        vm.prank(alice);
        uint256 r = miner.stake{value: 0.001 ether}(address(off), 1, 19); // no Cargo power needed
        vm.warp(block.timestamp + 5 minutes);
        vm.prank(alice);
        vm.expectRevert(CargoMiner.BadBerth.selector);
        miner.move(r, 0);
        vm.prank(alice);
        miner.move(r, 24);
        uint256 c = _stake(bob, s1, 2, 10, 19); // Cargo rigs may use official berths too
        assertGt(c, r);
    }

    function test_removeOfficialBlocksNewLoadsOnly() public {
        _whitelist();
        _stake(bob, s1, 1, 300, 0);
        uint256 r = _stake(alice, off, 1, 10, 19);
        vm.prank(founder);
        miner.removeOfficial(address(off));
        off.make(alice, 2, 1);
        vm.prank(alice);
        vm.expectRevert(CargoMiner.NotCargoCpu.selector);
        miner.stake(address(off), 2, 19);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        miner.unstake(r); // still sails, still unloads
        assertApproxEqAbs(cargo.balanceOf(alice), DAY_SHARE, 1e6);
        assertEq(off.ownerOf(1), alice);
        assertEq(miner.officialPower(), 0);
    }

    // ---------- Express ----------

    function test_expressSeats() public {
        uint256 r = _earn(alice, 1);
        uint256 bal = cargo.balanceOf(alice);
        vm.prank(alice);
        uint256 b = miner.buySeat(r);
        assertEq(b, miner.blockNow() + 1); // next block only
        assertEq(bal - cargo.balanceOf(alice), 10e18); // burned
        vm.prank(alice);
        vm.expectRevert(CargoMiner.SeatTaken.selector); // same rig twice
        miner.buySeat(r);
        uint256 r2 = _stake(alice, s1, 2, 10, 5);
        vm.prank(alice);
        miner.buySeat(r2);
        uint256 r3 = _stake(alice, s1, 3, 10, 6);
        vm.prank(alice);
        vm.expectRevert(CargoMiner.SeatLimit.selector);
        miner.buySeat(r3);
        vm.prank(bob);
        vm.expectRevert(CargoMiner.NotOwner.selector);
        miner.buySeat(r3);
    }

    function test_expressRewardProRataAfterBlock() public {
        uint256 ra = _earn(alice, 1); // 10 transistors
        uint256 rb = _stake(bob, s1, 2, 30, 7);
        vm.warp(block.timestamp + 1 days);
        _claim(bob, rb);
        vm.prank(bob);
        cargo.approve(address(miner), type(uint256).max);
        vm.prank(alice);
        uint256 b = miner.buySeat(ra);
        vm.prank(bob);
        miner.buySeat(rb);
        uint256[] memory bs = new uint256[](1);
        bs[0] = b;
        vm.prank(alice);
        vm.expectRevert(CargoMiner.NotEnded.selector);
        miner.claimExpress(bs);
        vm.warp(miner.start() + (b + 1) * 1 hours);
        uint256 a0 = cargo.balanceOf(alice);
        uint256 b0 = cargo.balanceOf(bob);
        vm.prank(alice);
        miner.claimExpress(bs);
        vm.prank(bob);
        miner.claimExpress(bs);
        uint256 budget = uint256(5_000e18) / 24 * 4 / 29;
        assertApproxEqAbs(cargo.balanceOf(alice) - a0, budget / 4, 1e9);
        assertApproxEqAbs(cargo.balanceOf(bob) - b0, budget * 3 / 4, 1e9);
        vm.prank(alice); // second claim pays nothing
        miner.claimExpress(bs);
        assertApproxEqAbs(cargo.balanceOf(alice) - a0, budget / 4, 1e9);
    }

    function test_expressPriceAdjusts() public {
        assertEq(miner.seatPrice(1), 10e18);
        uint256 r = _earn(alice, 1);
        vm.prank(alice);
        uint256 b = miner.buySeat(r); // 1 seat sold (< 10)
        assertEq(miner.seatPrice(b + 1), 9e18); // x0.9
        assertEq(miner.seatPrice(b + 2), 8.1e18); // + one empty block x0.9
        assertEq(miner.seatPrice(b + 1000), 1e18); // floor
        // fill block b+1 with 20 seats -> x1.1 for b+2, and sold out
        vm.warp(miner.start() + b * 1 hours); // now in block b, selling b+1
        for (uint256 i; i < 10; i++) {
            address w = makeAddr(string(abi.encode(i)));
            vm.deal(w, 1 ether);
            uint256 x = _stake(w, s1, 100 + i, 1, uint8(i));
            uint256 y = _stake(w, s1, 200 + i, 1, uint8(i));
            deal(address(cargo), w, 100e18, true); // adjust totalSupply (seats burn)
            vm.startPrank(w);
            cargo.approve(address(miner), type(uint256).max);
            miner.buySeat(x);
            miner.buySeat(y);
            vm.stopPrank();
        }
        assertEq(miner.seatsSold(b + 1), 20);
        uint256 r2 = _stake(alice, s1, 2, 1, 3);
        vm.prank(alice);
        vm.expectRevert(CargoMiner.SoldOut.selector);
        miner.buySeat(r2);
        assertEq(miner.seatPrice(b + 2), 9.9e18); // 9 x 1.1
    }

    // ---------- charter ----------

    function _token(address who, uint256 a) internal returns (MockToken t) {
        t = new MockToken();
        t.mint(who, a);
        vm.prank(who);
        t.approve(address(miner), type(uint256).max);
    }

    function test_charterStreamsProRata() public {
        MockToken t = _token(carol, 1_000e18);
        uint256 a = _stake(alice, s1, 1, 10, 4);
        uint256 b = _stake(bob, s1, 2, 30, 4);
        vm.prank(carol);
        vm.expectRevert(CargoMiner.WrongFee.selector);
        miner.charter{value: 0.1 ether}(4, 2016, address(t), 1_000e18);
        vm.prank(carol);
        miner.charter{value: 1.008 ether}(4, 2016, address(t), 1_000e18); // 7 days
        assertEq(miner.voyageFees(), 1.008 ether);
        vm.warp(block.timestamp + 14 days); // ends after 7 days
        _claim(alice, a);
        _claim(bob, b);
        assertApproxEqAbs(miner.tokenOwed(alice, address(t)), 250e18, 1e9);
        assertApproxEqAbs(miner.tokenOwed(bob, address(t)), 750e18, 1e9);
        vm.prank(alice);
        miner.claimToken(address(t));
        assertApproxEqAbs(t.balanceOf(alice), 250e18, 1e9);
        assertEq(miner.tokenOwed(alice, address(t)), 0);
    }

    function test_charterLateJoinerAndEmptyReclaim() public {
        MockToken t = _token(carol, 1_000e18);
        vm.prank(carol);
        uint256 id = miner.charter{value: 1.008 ether}(4, 2016, address(t), 1_000e18);
        vm.warp(block.timestamp + 3.5 days); // empty half -> back to charterer
        uint256 a = _stake(alice, s1, 1, 10, 4);
        vm.prank(carol);
        vm.expectRevert(CargoMiner.NotEnded.selector);
        miner.reclaimCharter(id);
        vm.warp(block.timestamp + 7 days);
        _claim(alice, a);
        assertApproxEqAbs(miner.tokenOwed(alice, address(t)), 500e18, 1e9);
        vm.prank(carol);
        miner.reclaimCharter(id);
        vm.prank(carol);
        miner.claimToken(address(t));
        assertApproxEqAbs(t.balanceOf(carol), 500e18, 1e9);
    }

    function test_charterRigIdleAcrossTwoCharters() public {
        MockToken t1 = _token(carol, 100e18);
        MockToken t2 = _token(carol, 300e18);
        uint256 a = _stake(alice, s1, 1, 10, 4);
        vm.prank(carol);
        vm.expectRevert(CargoMiner.BadCharter.selector);
        miner.charter{value: 0.0005 ether}(4, 1, address(t1), 100e18); // < 7 days
        vm.startPrank(carol);
        miner.charter{value: 1.008 ether}(4, 2016, address(t1), 100e18);
        vm.expectRevert(CargoMiner.BerthChartered.selector);
        miner.charter{value: 1.008 ether}(4, 2016, address(t2), 300e18);
        vm.warp(block.timestamp + 7 days);
        miner.charter{value: 1.008 ether}(4, 2016, address(t2), 300e18);
        vm.stopPrank();
        vm.warp(block.timestamp + 21 days);
        vm.prank(alice);
        miner.unstake(a);
        assertApproxEqAbs(miner.tokenOwed(alice, address(t1)), 100e18, 1e9);
        assertApproxEqAbs(miner.tokenOwed(alice, address(t2)), 300e18, 1e9);
    }

    function test_charterSyncInChunks() public {
        uint256 a = _stake(alice, s1, 1, 10, 4);
        MockToken t = _token(carol, 300e18);
        uint256 now_ = block.timestamp; // explicit clock: via-IR caches block.timestamp across vm.warp
        for (uint256 i; i < 3; i++) {
            vm.prank(carol);
            miner.charter{value: 1.008 ether}(4, 2016, address(t), 100e18);
            now_ += 7 days;
            vm.warp(now_);
        }
        miner.syncCharters(a, 2);
        assertApproxEqAbs(miner.tokenOwed(alice, address(t)), 200e18, 1e9);
        miner.syncCharters(a, 0); // no-op
        _claim(alice, a);
        assertApproxEqAbs(miner.tokenOwed(alice, address(t)), 300e18, 1e9);
        _claim(alice, a); // nothing twice
        assertApproxEqAbs(miner.tokenOwed(alice, address(t)), 300e18, 1e9);
    }

    function test_charterMaxTenAndFeeOnTransfer() public {
        MockToken t = _token(carol, 1_000e18);
        for (uint8 i; i < 10; i++) {
            vm.prank(carol);
            miner.charter{value: 1.008 ether}(i, 2016, address(t), 1e18);
        }
        assertEq(miner.charteredNow(), 10);
        vm.prank(carol);
        vm.expectRevert(CargoMiner.TooManyCharters.selector);
        miner.charter{value: 1.008 ether}(10, 2016, address(t), 1e18);
        vm.warp(block.timestamp + 7 days);
        MockToken f = _token(carol, 1_000e18);
        f.setFee(100);
        vm.prank(carol);
        vm.expectRevert(CargoMiner.BadCharter.selector);
        miner.charter{value: 1.008 ether}(10, 2016, address(f), 1e18);
        f.setFee(0);
        f.mint(carol, 1e31);
        vm.prank(carol);
        vm.expectRevert(CargoMiner.BadCharter.selector); // review H1: amount cap
        miner.charter{value: 1.008 ether}(10, 2016, address(f), 1e30 + 1);
    }

    /// Review H1: max charter amount on a 1-wei-power rig, then a huge rig joins: no overflow, exits still work.
    function test_charterMathNoOverflow() public {
        MockCircuit tiny = new MockCircuit(1);
        dock.add(address(tiny), 1); // season price 1 wei (season 3: CARGO burn rounds to 0)
        miner.setOracle(address(new MockOracle()));
        uint256 a = _stake(alice, tiny, 1, 1, 4); // power 1 wei
        MockToken t = _token(carol, 1e30);
        vm.prank(carol);
        miner.charter{value: 1.008 ether}(4, 2016, address(t), 1e30);
        vm.warp(block.timestamp + 3 days);
        uint256 b = _stake(bob, s1, 2, 500, 4); // 1 OKB power
        vm.warp(block.timestamp + 5 days);
        vm.prank(alice);
        miner.unstake(a);
        vm.prank(bob);
        miner.unstake(b);
        assertApproxEqRel(miner.tokenOwed(alice, address(t)) + miner.tokenOwed(bob, address(t)), 1e30, 1e15);
    }

    // ---------- bills of lading ----------

    function test_billSale() public {
        _wire();
        uint256 r = _stake(alice, s1, 1, 10, 0);
        vm.prank(alice);
        vm.expectRevert(CargoMiner.NotAllowed.selector);
        miner.transferFrom(alice, bob, r);
        vm.prank(bob);
        vm.expectRevert(CargoMiner.NotListed.selector);
        miner.buy{value: 1 ether}(r, 0);
        vm.prank(bob);
        vm.expectRevert(CargoMiner.NotOwner.selector);
        miner.list(r, 1 ether);
        vm.prank(alice);
        miner.list(r, 1 ether);
        vm.warp(block.timestamp + 1 days);
        uint256 a0 = alice.balance;
        vm.prank(bob);
        vm.expectRevert(CargoMiner.WrongFee.selector);
        miner.buy{value: 0.5 ether}(r, 0);
        vm.prank(bob);
        miner.buy{value: 1 ether}(r, 0);
        assertEq(alice.balance - a0, 0.99 ether);
        assertEq(miner.voyageFees(), 0.01 ether);
        assertApproxEqAbs(cargo.balanceOf(alice), DAY_SHARE, 1e6); // seller keeps pending
        assertEq(miner.ownerOf(r), bob);
        assertEq(miner.balanceOf(alice), 0);
        assertEq(miner.balanceOf(bob), 1);
        assertEq(miner.s1PowerOf(alice), 0);
        assertEq(miner.s1PowerOf(bob), 0.02 ether);
        (,,,,,,,,,,, uint256 price) = miner.rigs(r);
        assertEq(price, 0); // delisted
        vm.warp(block.timestamp + 1 days);
        vm.prank(bob);
        miner.unstake(r);
        assertEq(s1.ownerOf(1), bob);
        assertApproxEqAbs(cargo.balanceOf(bob), DAY_SHARE, 1e6);
    }

    /// Review M2 + L4: fee floor on power value, and a moved rig cannot be sold at the old berth.
    function test_billFeeFloorAndBerthGuard() public {
        uint256 r = _stake(alice, s1, 1, 500, 0); // 1 OKB power -> fee >= 0.01 OKB
        vm.prank(alice);
        miner.list(r, 1);
        vm.deal(bob, 100 ether);
        vm.prank(bob);
        vm.expectRevert(CargoMiner.WrongFee.selector); // 1 wei < 1% of power
        miner.buy{value: 1}(r, 0);
        vm.prank(alice);
        miner.list(r, 0.5 ether);
        vm.warp(block.timestamp + 5 minutes);
        vm.prank(alice);
        miner.move(r, 3);
        vm.prank(bob);
        vm.expectRevert(CargoMiner.WrongFee.selector); // seller moved it
        miner.buy{value: 0.5 ether}(r, 0);
        uint256 a0 = alice.balance;
        vm.prank(bob);
        miner.buy{value: 0.5 ether}(r, 3);
        assertEq(miner.voyageFees(), 0.01 ether); // 1% of 1 OKB power, not of 0.5
        assertEq(alice.balance - a0, 0.49 ether);
    }

    function test_billBuyRespectsWalletCap() public {
        uint256 r = _stake(alice, s1, 1, 100, 0);
        _stake(bob, s1, 2, 450, 1); // 0.9 OKB
        vm.prank(alice);
        miner.list(r, 1 ether);
        vm.prank(bob);
        vm.expectRevert(CargoMiner.WalletCap.selector);
        miner.buy{value: 1 ether}(r, 0);
    }

    function test_revertingSellerBlocksOnlyOwnSale() public {
        RevertingSeller s = new RevertingSeller();
        s1.make(address(s), 1, 10);
        uint256 r = s.stake{value: 0.001 ether}(miner, s1, 1);
        s.list(miner, r, 1 ether);
        vm.prank(bob);
        vm.expectRevert(CargoMiner.SendFailed.selector);
        miner.buy{value: 1 ether}(r, 0);
    }

    // ---------- fees + wiring ----------

    function test_sweepVoyageFees() public {
        MockToken t = _token(carol, 1e18);
        vm.prank(carol);
        miner.charter{value: 1.008 ether}(0, 2016, address(t), 1e18);
        vm.expectRevert(CargoMiner.NotWired.selector);
        miner.sweepVoyageFees();
        _wire();
        miner.sweepVoyageFees();
        assertEq(bemPol.balance, 0.3528 ether);
        assertEq(team.balance, 0.3528 ether);
        assertEq(burner.balance, 0.1512 ether);
        assertEq(reserve.balance, 0.1512 ether);
        assertEq(miner.voyageFees(), 0);
    }

    function test_wiringOnce() public {
        _wire();
        vm.expectRevert(CargoMiner.NotAllowed.selector);
        miner.setSinks(bemPol, burner, reserve, team);
        miner.setOracle(address(new MockOracle()));
        vm.expectRevert(CargoMiner.NotAllowed.selector);
        miner.setOracle(address(1));
    }

    /// Review M4: Y30 streams over 24h, Cargo rigs only; a just-in-time rig gets only its time share.
    function test_yieldOkbStreamed() public {
        _whitelist();
        uint256 a = _stake(alice, s1, 1, 10, 0);
        uint256 b = _stake(bob, s1, 2, 30, 9);
        uint256 o = _stake(alice, off, 1, 100, 19); // official: no Y30
        miner.notifyOkb{value: 1 ether}();
        (, uint256 oa) = miner.pending(a);
        assertEq(oa, 0); // nothing at once
        vm.warp(block.timestamp + 23 hours);
        uint256 j = _stake(carol, s1, 3, 40, 2); // JIT rig, same power as alice + bob
        vm.warp(block.timestamp + 2 hours); // stream over
        (, oa) = miner.pending(a);
        (, uint256 ob) = miner.pending(b);
        (, uint256 oj) = miner.pending(j);
        (, uint256 oo) = miner.pending(o);
        uint256 lastHour = uint256(1 ether) / 24;
        assertApproxEqAbs(oj, lastHour / 2, 1e9);
        assertApproxEqAbs(oa, (1 ether - lastHour) / 4 + lastHour / 8, 1e9);
        assertApproxEqAbs(ob, (1 ether - lastHour) * 3 / 4 + lastHour * 3 / 8, 1e9);
        assertEq(oo, 0);
        uint256 a0 = alice.balance;
        _claim(alice, a);
        assertApproxEqAbs(alice.balance - a0, oa, 1e9);
    }

    function test_yieldOkbIdleCarriedOver() public {
        uint256 now_ = block.timestamp; // explicit clock (via-IR)
        miner.notifyOkb{value: 1 ether}(); // no rigs: streams into unallocated
        vm.warp(now_ + 1 days);
        uint256 a = _stake(alice, s1, 1, 10, 0);
        miner.notifyOkb(); // restream the idle OKB
        vm.warp(now_ + 2 days);
        (, uint256 oa) = miner.pending(a);
        assertApproxEqAbs(oa, 1 ether, 1e9);
    }

    /// Review R3-M1: dust/zero notifies join the running stream and cannot push its end out; >= 0.001 OKB restarts 24h.
    function test_notifyDustCannotDelay() public {
        uint256 now_ = 1_000_000; // literal clock: via-IR re-reads block.timestamp for a copied variable
        vm.warp(now_);
        uint256 a = _stake(alice, s1, 1, 10, 0);
        miner.notifyOkb{value: 1 ether}();
        uint64 end0 = miner.okbEnd();
        for (uint256 i = 1; i <= 20; i++) {
            vm.warp(now_ + i * 1 hours);
            miner.notifyOkb(); // griefing attempt
            miner.notifyOkb{value: 0.0009 ether}();
        }
        assertEq(miner.okbEnd(), end0);
        vm.warp(now_ + 1 days);
        (, uint256 oa) = miner.pending(a);
        assertApproxEqAbs(oa, 1 ether + 20 * 0.0009 ether, 1e9); // all paid by the original end
        miner.notifyOkb{value: 0.001 ether}(); // stream over: a new 24h window
        assertEq(miner.okbEnd(), now_ + 2 days);
        vm.warp(now_ + 1 days + 1 hours);
        miner.notifyOkb{value: 0.001 ether}(); // >= MIN_RESTREAM restarts
        assertEq(miner.okbEnd(), now_ + 1 days + 1 hours + 1 days);
    }

    /// Review M5: owner can replace oracle + sinks only after 48h.
    function test_wiringTimelock() public {
        vm.prank(alice);
        vm.expectRevert(CargoMiner.NotOwner.selector);
        miner.queueWiring(address(1), bemPol, burner, reserve, team);
        vm.startPrank(founder);
        vm.expectRevert(CargoMiner.NotAllowed.selector);
        miner.applyWiring();
        miner.queueWiring(address(1), bemPol, burner, reserve, team);
        vm.expectRevert(CargoMiner.Timelocked.selector);
        miner.applyWiring();
        vm.warp(block.timestamp + 48 hours);
        miner.applyWiring();
        vm.stopPrank();
        assertEq(address(miner.oracle()), address(1));
        assertEq(miner.team(), team);
    }

    /// Review L1: one Express seat per circuit per block, even after unload + reload.
    function test_seatPerCircuitNotPerRig() public {
        uint256 r = _earn(alice, 1);
        vm.prank(alice);
        miner.buySeat(r);
        vm.prank(alice);
        miner.unstake(r);
        uint256 fee = miner.dockFeeFor(address(s1), 1);
        vm.prank(alice);
        uint256 r2 = miner.stake{value: fee}(address(s1), 1, 3);
        vm.prank(alice);
        vm.expectRevert(CargoMiner.SeatTaken.selector);
        miner.buySeat(r2);
    }
}
