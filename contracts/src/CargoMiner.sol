// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./UniV3Lib.sol"; // mulDiv

// CargoMiner v2 — Cargo Voyage (X Layer). Spec: docs/cargo-voyage-spec.md.
//   Ship      = 25 berths, a voyage every 5 min. A loaded circuit (rig) sails voyage after voyage until unloaded.
//   Emission  = 5,000 CARGO/day flat, 10M cap. Split in 29 shares: 25 berths + 4 Express. A berth's share goes
//               pro-rata by power to the rigs in it. Empty berth / unsold Express block = never minted.
//   Power     = NAND + LATCH in netlist(id) x price (OKB wei). Cargo season CPU: season price. Official TapeOut CPU
//               (whitelisted, 48h timelock): its mintPrice x 50%, only in berths 19-24 (<= 6/29 of CARGO), no Y30 OKB.
//   Load      = 5% of power paid in OKB as dock fee (-> CargoDock.payDockFee); Cargo season >= 2 also burns CARGO
//               worth 20% of power. A rig may move once per voyage.
//   Express   = 20 seats per 1h block, bought in CARGO (burned) for the next block only, max 2 per wallet. Price per
//               block: x1.1 if >= 18 sold, x0.9 if < 10, floor 1 CARGO. Seat reward = Express share pro-rata by power.
//   Charter   = an outside project prepays 0.0005 OKB/voyage for one berth (7-90 days, max 10 berths at once) and
//               streams its own ERC-20 to the rigs in it. Token rewards are credited, paid by claimToken (no DoS).
//   Bill      = each rig is an ERC-721 bill of lading. Transfers only via list/buy, 1% fee in OKB.
//   Fees      = charter + bill fees: 35 BEM-OKB POL / 35 team / 15 burner / 15 reserve (sweepVoyageFees).
//   Yield Y30 = notifyOkb() OKB streamed over 24h, pro-rata by power over Cargo rigs (no just-in-time sniping).
// Unload returns the circuit, no refund. Owner can only whitelist official CPUs (48h), remove them for new loads,
// or replace oracle/fee sinks (48h). No owner path touches loaded circuits or rewards.

interface ICargoToken {
    function mint(address to, uint256 amount) external;
    function burnFrom(address from, uint256 amount) external;
}

interface IDock {
    function seasonOf(address cpu) external view returns (uint256);
    function seasons(uint256) external view returns (address, address, uint128, uint64, uint64);
    function payDockFee() external payable;
}

interface ITapeoutFactory {
    function cpuAt(uint256) external view returns (address);
}

interface ICircuitNft {
    function netlist(uint256 id) external view returns (bytes memory);
    function transferFrom(address from, address to, uint256 id) external;
    function transistorsContract() external view returns (address);
}

interface ITransistorsPrice {
    function mintPrice() external view returns (uint256);
}

interface ICargoOracle {
    /// CARGO (wei) worth `okb` OKB (wei), TWAP-based.
    function cargoForOkb(uint256 okb) external view returns (uint256);
}

interface IERC20Charter {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

contract CargoMiner {
    uint256 public constant BERTHS = 25;
    uint256 public constant SHARES = 29; // 25 berths + 4 Express
    uint256 public constant EXPRESS_SHARES = 4;
    uint256 public constant VOYAGE = 5 minutes;
    uint256 public constant BLOCK = 1 hours;
    uint256 public constant DAILY = 5_000e18;
    uint256 public constant EMISSION_CAP = 10_000_000e18;
    uint256 public constant DOCK_FEE_BPS = 500;
    uint256 public constant CARGO_BURN_BPS = 2_000; // Cargo season >= 2
    uint256 public constant OFF_WEIGHT_BPS = 5_000;
    uint256 public constant OFF_BERTH = 19; // official circuits only in berths 19..24
    uint256 public constant OKB_STREAM = 1 days;
    uint256 public constant MIN_RESTREAM = 0.001 ether;
    uint256 public constant MAX_OFFICIAL = 20;
    uint256 public constant TIMELOCK = 48 hours;
    uint32 public constant OFFICIAL = type(uint32).max; // Rig.season for official circuits

    uint256 public constant SEATS = 20;
    uint256 public constant SEATS_PER_WALLET = 2;
    uint256 public constant SEAT_START = 10e18;
    uint256 public constant SEAT_FLOOR = 1e18;
    uint256 public constant SEAT_MAX = 100_000e18;

    uint256 public constant CHARTER_FEE = 0.0005 ether; // per berth per voyage
    uint256 public constant CHARTER_MIN = 288 * 7; // 7 days (review M1: no cheap berth squatting)
    uint256 public constant CHARTER_MAX = 288 * 90;
    uint256 public constant MAX_CHARTERED = 10;
    uint256 public constant MAX_CHARTER_AMOUNT = 1e30; // review H1: bounds charter math

    uint256 public constant SALE_FEE_BPS = 100;
    uint256 public constant FEE_BEM_BPS = 3_500;
    uint256 public constant FEE_TEAM_BPS = 3_500;
    uint256 public constant FEE_BURN_BPS = 1_500; // rest -> reserve

    uint256 private constant ACC = 1e18;
    uint256 private constant XACC = 1e24;

    string public constant name = "Cargo Bill of Lading";
    string public constant symbol = "CBOL";

    ICargoToken public immutable cargo;
    IDock public immutable dock;
    ITapeoutFactory public immutable factory;
    address public immutable owner;
    uint256 public immutable start;
    uint256 public immutable walletCapS1; // max power per wallet on season-1 rigs (0 = none)

    ICargoOracle public oracle;
    address public bemPol;
    address public burner;
    address public reserve;
    address public team;
    address private deployer;

    struct Wiring { address oracle; address bemPol; address burner; address reserve; address team; uint64 readyAt; }
    Wiring public pendingWiring;

    struct Berth { uint128 power; uint64 last; uint256 acc; }
    Berth[BERTHS] public berths;

    struct Rig {
        address owner;
        address cpu;
        uint64 voyageMoved;
        uint8 berth;
        uint32 season; // Cargo season index, or OFFICIAL
        uint32 cIdx; // first charter of this berth not fully settled for the rig
        uint256 id;
        uint256 power;
        uint256 cargoDebt;
        uint256 okbDebt;
        uint256 xDebt; // debt on charter cIdx
        uint256 price; // bill listing in OKB (0 = not listed)
    }
    Rig[] public rigs;
    mapping(address => mapping(uint256 => uint256)) public rigOf; // cpu => circuit id => rig index + 1
    mapping(address => uint256) public s1PowerOf;
    mapping(address => uint256) public balanceOf; // bills

    struct Official { uint128 refPrice; uint64 readyAt; bool active; }
    mapping(address => Official) public officials;
    uint256 public officialCount;
    uint256 public officialPower;

    struct Charter {
        address charterer;
        address token;
        uint8 berth;
        uint64 from;
        uint64 until;
        uint64 last;
        uint256 amount;
        uint256 acc;
        uint256 unalloc; // streamed while the berth was empty -> back to charterer
    }
    Charter[] public charters;
    mapping(uint256 => uint256[]) internal berthCharters; // berth => charter ids
    mapping(address => mapping(address => uint256)) public tokenOwed; // user => token => amount

    mapping(uint256 => uint256) public seatsSold; // block => seats
    mapping(uint256 => uint256) public blockPower;
    mapping(uint256 => mapping(address => uint256)) public seatPower;
    mapping(uint256 => mapping(address => uint256)) public seatsOf;
    mapping(uint256 => mapping(bytes32 => bool)) public seatUsed; // block => keccak(cpu, id): one seat per circuit
    uint256 public lastSeatBlock;
    uint256 public lastSeatPrice;
    bool public seatPriced;

    uint256 public totalPower;
    uint256 public okbRateX; // Y30 OKB per second x ACC
    uint64 public okbEnd;
    uint64 public okbLast;
    uint256 public accOkb;
    uint256 public unallocatedOkb;
    uint256 public totalMinted;
    uint256 public booked; // CARGO assigned to occupied berths + sold Express blocks (claimed or not)
    uint256 public voyageFees;
    uint256 private locked = 1;

    event Staked(uint256 indexed rig, address indexed owner, address cpu, uint256 id, uint256 power, uint8 berth, uint256 cargoBurned);
    event Moved(uint256 indexed rig, uint8 from, uint8 to);
    event Claimed(uint256 indexed rig, address indexed owner, uint256 cargo, uint256 okb);
    event Unstaked(uint256 indexed rig, address indexed owner);
    event OkbNotified(address indexed from, uint256 okb);
    event OracleSet(address oracle);
    event SinksSet(address bemPol, address burner, address reserve, address team);
    event WiringQueued(address oracle, address bemPol, address burner, address reserve, address team, uint256 readyAt);
    event OfficialQueued(address indexed cpu, uint256 refPrice, uint256 readyAt);
    event OfficialSet(address indexed cpu, bool active);
    event SeatBought(uint256 indexed blk, address indexed buyer, uint256 indexed rig, uint256 price);
    event ExpressClaimed(uint256 indexed blk, address indexed user, uint256 cargo);
    event Chartered(uint256 indexed charter, uint8 indexed berth, address indexed charterer, address token, uint256 amount, uint256 voyages);
    event TokenClaimed(address indexed user, address indexed token, uint256 amount);
    event Listed(uint256 indexed rig, uint256 price);
    event Sold(uint256 indexed rig, address indexed seller, address indexed buyer, uint256 price, uint256 fee);
    event VoyageFeesSwept(uint256 okb);
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    error NotAllowed();
    error NotCargoCpu();
    error NotOwner();
    error AlreadyStaked();
    error BadBerth();
    error BadNetlist();
    error NoPower();
    error WrongFee();
    error WalletCap();
    error NoOracle();
    error MovedThisVoyage();
    error Reentrant();
    error SendFailed();
    error Timelocked();
    error BadCpu();
    error SoldOut();
    error SeatLimit();
    error SeatTaken();
    error NotEnded();
    error BadCharter();
    error BerthChartered();
    error TooManyCharters();
    error NotListed();
    error NotWired();

    modifier nonReentrant() {
        if (locked != 1) revert Reentrant();
        locked = 2;
        _;
        locked = 1;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address cargo_, address dock_, address factory_, address owner_, uint256 start_, uint256 walletCapS1_) {
        cargo = ICargoToken(cargo_);
        dock = IDock(dock_);
        factory = ITapeoutFactory(factory_);
        owner = owner_;
        start = start_;
        walletCapS1 = walletCapS1_;
        deployer = msg.sender;
        for (uint256 t; t < BERTHS; t++) berths[t].last = uint64(start_);
    }

    // ---------- wiring (deployer, once each) ----------

    function setOracle(address o) external {
        if (msg.sender != deployer || o == address(0) || address(oracle) != address(0)) revert NotAllowed();
        oracle = ICargoOracle(o);
        if (team != address(0)) deployer = address(0);
        emit OracleSet(o);
    }

    function setSinks(address bemPol_, address burner_, address reserve_, address team_) external {
        if (msg.sender != deployer || team != address(0)) revert NotAllowed();
        if (bemPol_ == address(0) || burner_ == address(0) || reserve_ == address(0) || team_ == address(0)) {
            revert NotAllowed();
        }
        (bemPol, burner, reserve, team) = (bemPol_, burner_, reserve_, team_);
        if (address(oracle) != address(0)) deployer = address(0);
        emit SinksSet(bemPol_, burner_, reserve_, team_);
    }

    /// Owner: replace oracle + fee sinks (all five, non-zero), active after 48h via applyWiring.
    function queueWiring(address o, address bemPol_, address burner_, address reserve_, address team_) external onlyOwner {
        if (o == address(0) || bemPol_ == address(0) || burner_ == address(0) || reserve_ == address(0) || team_ == address(0)) {
            revert NotAllowed();
        }
        pendingWiring = Wiring(o, bemPol_, burner_, reserve_, team_, uint64(block.timestamp + TIMELOCK));
        emit WiringQueued(o, bemPol_, burner_, reserve_, team_, block.timestamp + TIMELOCK);
    }

    function applyWiring() external onlyOwner {
        Wiring memory w = pendingWiring;
        if (w.readyAt == 0) revert NotAllowed();
        if (block.timestamp < w.readyAt) revert Timelocked();
        delete pendingWiring;
        oracle = ICargoOracle(w.oracle);
        (bemPol, burner, reserve, team) = (w.bemPol, w.burner, w.reserve, w.team);
        emit OracleSet(w.oracle);
        emit SinksSet(w.bemPol, w.burner, w.reserve, w.team);
    }

    // ---------- official TapeOut CPUs ----------

    /// Queue a TapeOut CPU (factory index `idx`) as official. Active after 48h via addOfficial.
    function queueOfficial(address cpu, uint256 idx) external onlyOwner {
        if (factory.cpuAt(idx) != cpu || dock.seasonOf(cpu) != 0 || officials[cpu].active) revert BadCpu();
        uint256 p = ITransistorsPrice(ICircuitNft(cpu).transistorsContract()).mintPrice();
        if (p == 0 || p > type(uint128).max) revert BadCpu();
        officials[cpu] = Official(uint128(p), uint64(block.timestamp + TIMELOCK), false);
        emit OfficialQueued(cpu, p, block.timestamp + TIMELOCK);
    }

    function addOfficial(address cpu) external onlyOwner {
        Official storage O = officials[cpu];
        if (O.readyAt == 0 || O.active) revert BadCpu();
        if (block.timestamp < O.readyAt) revert Timelocked();
        if (officialCount >= MAX_OFFICIAL) revert BadCpu();
        O.active = true;
        officialCount++;
        emit OfficialSet(cpu, true);
    }

    /// Blocks new loads only. Loaded circuits keep sailing until their owner unloads.
    function removeOfficial(address cpu) external onlyOwner {
        Official storage O = officials[cpu];
        if (!O.active) revert BadCpu();
        O.active = false;
        O.readyAt = 0;
        officialCount--;
        emit OfficialSet(cpu, false);
    }

    // ---------- schedule ----------

    /// CARGO scheduled from start until t (all 29 shares). Flat 5,000/day up to 10M.
    function emittedUntil(uint256 t) public view returns (uint256) {
        if (t <= start) return 0;
        uint256 e = DAILY * (t - start) / 1 days;
        return e < EMISSION_CAP ? e : EMISSION_CAP;
    }

    function voyageNow() public view returns (uint256) {
        return block.timestamp < start ? 0 : (block.timestamp - start) / VOYAGE;
    }

    function blockNow() public view returns (uint256) {
        return block.timestamp < start ? 0 : (block.timestamp - start) / BLOCK;
    }

    /// Value of a circuit as a rig, in OKB wei. 0 if its CPU is neither a Cargo season nor an active official CPU.
    function powerOf(address cpu, uint256 id) public view returns (uint256 power, uint256 season) {
        season = dock.seasonOf(cpu);
        if (season != 0) {
            season -= 1;
            (,, uint128 price,,) = dock.seasons(season);
            power = transistorCount(ICircuitNft(cpu).netlist(id)) * price;
        } else {
            Official storage O = officials[cpu];
            if (!O.active) return (0, 0);
            season = OFFICIAL;
            power = transistorCount(ICircuitNft(cpu).netlist(id)) * O.refPrice * OFF_WEIGHT_BPS / 10_000;
        }
    }

    /// NAND (op 0, 7 bytes) + LATCH (op 1, 4 bytes); REF (op 2) skipped: its gates live in another circuit.
    function transistorCount(bytes memory n) public pure returns (uint256 c) {
        uint256 i;
        uint256 len = n.length;
        while (i < len) {
            uint8 op = uint8(n[i]);
            if (op == 0) {
                c++;
                i += 7;
            } else if (op == 1) {
                c++;
                i += 4;
            } else if (op == 2) {
                if (i + 30 >= len) revert BadNetlist();
                i += 31 + 3 * uint256(uint8(n[i + 29])); // op, cpu(20), id(8), nIns, nOut, nIns x u24
            } else {
                revert BadNetlist();
            }
        }
        if (i != len) revert BadNetlist();
    }

    // ---------- rigs ----------

    /// Load a circuit into a berth. msg.value = 5% dock fee (dockFeeFor). Cargo season >= 2: approve CARGO first.
    function stake(address cpu, uint256 id, uint8 berth) external payable nonReentrant returns (uint256 r) {
        if (berth >= BERTHS) revert BadBerth();
        if (rigOf[cpu][id] != 0) revert AlreadyStaked();
        (uint256 power, uint256 season) = powerOf(cpu, id);
        if (season == 0 && dock.seasonOf(cpu) == 0) revert NotCargoCpu();
        if (power == 0) revert NoPower();
        if (msg.value != power * DOCK_FEE_BPS / 10_000) revert WrongFee();
        if (season == OFFICIAL) {
            if (berth < OFF_BERTH) revert BadBerth();
            officialPower += power;
        } else if (season == 0 && walletCapS1 != 0) {
            uint256 p = s1PowerOf[msg.sender] + power;
            if (p > walletCapS1) revert WalletCap();
            s1PowerOf[msg.sender] = p;
        }

        ICircuitNft(cpu).transferFrom(msg.sender, address(this), id); // reverts unless sender owns/approved

        uint256 burned;
        if (season > 0 && season != OFFICIAL) {
            if (address(oracle) == address(0)) revert NoOracle();
            burned = oracle.cargoForOkb(power * CARGO_BURN_BPS / 10_000);
            cargo.burnFrom(msg.sender, burned);
        }
        dock.payDockFee{value: msg.value}();

        _updateOkb();
        _update(berth);
        Berth storage B = berths[berth];
        B.power += uint128(power);
        totalPower += power;
        r = rigs.length;
        rigs.push();
        Rig storage R = rigs[r];
        R.owner = msg.sender;
        R.cpu = cpu;
        R.voyageMoved = uint64(voyageNow());
        R.berth = berth;
        R.season = uint32(season);
        R.id = id;
        R.power = power;
        R.cargoDebt = power * B.acc / ACC;
        if (season != OFFICIAL) R.okbDebt = power * accOkb / ACC;
        _joinCharters(R);
        rigOf[cpu][id] = r + 1;
        balanceOf[msg.sender]++;
        emit Transfer(address(0), msg.sender, r);
        emit Staked(r, msg.sender, cpu, id, power, berth, burned);
    }

    /// Move a rig to another berth (once per voyage). Pending rewards are paid first.
    function move(uint256 r, uint8 to) external nonReentrant {
        Rig storage R = rigs[r];
        if (R.owner != msg.sender) revert NotOwner();
        if (to >= BERTHS || (R.season == OFFICIAL && to < OFF_BERTH)) revert BadBerth();
        uint256 v = voyageNow();
        if (R.voyageMoved == v) revert MovedThisVoyage();
        _claim(r);
        uint8 from = R.berth;
        berths[from].power -= uint128(R.power);
        _update(to);
        berths[to].power += uint128(R.power);
        R.berth = to;
        R.voyageMoved = uint64(v);
        R.cargoDebt = R.power * berths[to].acc / ACC;
        _joinCharters(R);
        emit Moved(r, from, to);
    }

    function claim(uint256[] calldata rs) external nonReentrant {
        for (uint256 i; i < rs.length; i++) {
            if (rigs[rs[i]].owner != msg.sender) revert NotOwner();
            _claim(rs[i]);
        }
    }

    /// Returns the circuit to its owner after paying what it earned. No refund of fees or burned CARGO.
    function unstake(uint256 r) external nonReentrant {
        Rig storage R = rigs[r];
        if (R.owner != msg.sender) revert NotOwner();
        _claim(r);
        berths[R.berth].power -= uint128(R.power);
        totalPower -= R.power;
        if (R.season == OFFICIAL) officialPower -= R.power;
        else if (R.season == 0 && walletCapS1 != 0) s1PowerOf[msg.sender] -= R.power;
        rigOf[R.cpu][R.id] = 0;
        balanceOf[msg.sender]--;
        address cpu = R.cpu;
        uint256 id = R.id;
        delete rigs[r];
        emit Transfer(msg.sender, address(0), r);
        ICircuitNft(cpu).transferFrom(address(this), msg.sender, id);
        emit Unstaked(r, msg.sender);
    }

    /// Settle charter credits in chunks (only needed if a rig sat through very many charters).
    function syncCharters(uint256 r, uint256 maxSteps) external nonReentrant {
        Rig storage R = rigs[r];
        if (R.owner == address(0)) revert NotOwner();
        _update(R.berth);
        _settleCharters(R, maxSteps);
    }

    // ---------- bills of lading ----------

    /// List a bill for sale in OKB (0 = delist).
    function list(uint256 r, uint256 price) external {
        if (rigs[r].owner != msg.sender) revert NotOwner();
        rigs[r].price = price;
        emit Listed(r, price);
    }

    /// Buy a listed bill in berth `berth` (reverts if the seller moved it). msg.value = price; fee = 1% of
    /// max(price, power) (no 1-wei bypass); seller gets price - fee and the rig's pending rewards.
    function buy(uint256 r, uint8 berth) external payable nonReentrant {
        Rig storage R = rigs[r];
        address seller = R.owner;
        uint256 price = R.price;
        if (seller == address(0) || price == 0) revert NotListed();
        if (msg.value != price || msg.sender == seller || R.berth != berth) revert WrongFee();
        uint256 fee = (price > R.power ? price : R.power) * SALE_FEE_BPS / 10_000;
        if (price < fee) revert WrongFee();
        if (R.season == 0 && walletCapS1 != 0) {
            uint256 p = s1PowerOf[msg.sender] + R.power;
            if (p > walletCapS1) revert WalletCap();
            s1PowerOf[msg.sender] = p;
            s1PowerOf[seller] -= R.power;
        }
        _claim(r);
        R.owner = msg.sender;
        R.price = 0;
        balanceOf[seller]--;
        balanceOf[msg.sender]++;
        voyageFees += fee;
        emit Transfer(seller, msg.sender, r);
        emit Sold(r, seller, msg.sender, price, fee);
        _send(seller, price - fee);
    }

    function ownerOf(uint256 r) external view returns (address o) {
        if (r >= rigs.length || (o = rigs[r].owner) == address(0)) revert NotOwner();
    }

    function supportsInterface(bytes4 i) external pure returns (bool) {
        return i == 0x80ac58cd || i == 0x01ffc9a7; // ERC-721, ERC-165
    }

    function getApproved(uint256) external pure returns (address) {
        return address(0);
    }

    function isApprovedForAll(address, address) external pure returns (bool) {
        return false;
    }

    /// Bills move only through buy() (1% fee).
    function transferFrom(address, address, uint256) external pure {
        revert NotAllowed();
    }

    function safeTransferFrom(address, address, uint256) external pure {
        revert NotAllowed();
    }

    function safeTransferFrom(address, address, uint256, bytes calldata) external pure {
        revert NotAllowed();
    }

    function approve(address, uint256) external pure {
        revert NotAllowed();
    }

    function setApprovalForAll(address, bool) external pure {
        revert NotAllowed();
    }

    // ---------- Express ----------

    /// Seat price for block b (b >= the last priced block).
    function seatPrice(uint256 b) public view returns (uint256 p) {
        if (!seatPriced) return SEAT_START;
        p = lastSeatPrice;
        if (b <= lastSeatBlock) return p;
        uint256 s = seatsSold[lastSeatBlock];
        if (s >= 18) p = p * 11 / 10 < SEAT_MAX ? p * 11 / 10 : SEAT_MAX;
        else if (s < 10) p = p * 9 / 10 > SEAT_FLOOR ? p * 9 / 10 : SEAT_FLOOR;
        for (uint256 n = b - lastSeatBlock - 1; n > 0 && p > SEAT_FLOOR; n--) { // blocks with no sale
            p = p * 9 / 10 > SEAT_FLOOR ? p * 9 / 10 : SEAT_FLOOR;
        }
    }

    /// Buy an Express seat for the next 1h block with one of your rigs. Burns the seat price in CARGO (approve first).
    function buySeat(uint256 r) external nonReentrant returns (uint256 b) {
        Rig storage R = rigs[r];
        if (R.owner != msg.sender) revert NotOwner();
        b = blockNow() + 1;
        if (seatsSold[b] >= SEATS) revert SoldOut();
        if (seatsOf[b][msg.sender] >= SEATS_PER_WALLET) revert SeatLimit();
        bytes32 k = keccak256(abi.encode(R.cpu, R.id));
        if (seatUsed[b][k]) revert SeatTaken();
        uint256 p = seatPrice(b);
        if (!seatPriced || b != lastSeatBlock) (seatPriced, lastSeatBlock, lastSeatPrice) = (true, b, p);
        if (seatsSold[b] == 0) booked += expressBudget(b);
        seatsSold[b]++;
        seatsOf[b][msg.sender]++;
        seatUsed[b][k] = true;
        seatPower[b][msg.sender] += R.power;
        blockPower[b] += R.power;
        cargo.burnFrom(msg.sender, p);
        emit SeatBought(b, msg.sender, r, p);
    }

    function expressBudget(uint256 b) public view returns (uint256) {
        return (emittedUntil(start + (b + 1) * BLOCK) - emittedUntil(start + b * BLOCK)) * EXPRESS_SHARES / SHARES;
    }

    /// Claim Express rewards of ended blocks.
    function claimExpress(uint256[] calldata bs) external nonReentrant {
        uint256 total;
        uint256 now_ = blockNow();
        for (uint256 i; i < bs.length; i++) {
            uint256 b = bs[i];
            if (b >= now_ || block.timestamp < start) revert NotEnded();
            uint256 sp = seatPower[b][msg.sender];
            if (sp == 0) continue;
            seatPower[b][msg.sender] = 0;
            uint256 c = expressBudget(b) * sp / blockPower[b];
            total += c;
            emit ExpressClaimed(b, msg.sender, c);
        }
        if (total > 0) {
            totalMinted += total;
            cargo.mint(msg.sender, total);
        }
    }

    // ---------- charter ----------

    /// Charter berth `berth` for `voyages` voyages from now: msg.value = voyages x 0.0005 OKB; `amount` of `token`
    /// (approve first; fee-on-transfer tokens rejected) streams pro-rata to the rigs in that berth.
    function charter(uint8 berth, uint256 voyages, address token, uint256 amount)
        external
        payable
        nonReentrant
        returns (uint256 id)
    {
        if (berth >= BERTHS || voyages < CHARTER_MIN || voyages > CHARTER_MAX) revert BadCharter();
        if (token == address(0) || token.code.length == 0 || amount == 0 || amount > MAX_CHARTER_AMOUNT) revert BadCharter();
        if (msg.value != voyages * CHARTER_FEE) revert WrongFee();
        uint256[] storage ids = berthCharters[berth];
        if (ids.length > 0 && charters[ids[ids.length - 1]].until > block.timestamp) revert BerthChartered();
        if (charteredNow() >= MAX_CHARTERED) revert TooManyCharters();
        _update(berth); // finalize the previous charter
        uint256 bal = IERC20Charter(token).balanceOf(address(this));
        _safeTransferFrom(token, msg.sender, amount);
        if (IERC20Charter(token).balanceOf(address(this)) - bal != amount) revert BadCharter();
        id = charters.length;
        uint64 from = uint64(block.timestamp);
        charters.push(Charter({
            charterer: msg.sender,
            token: token,
            berth: berth,
            from: from,
            until: uint64(block.timestamp + voyages * VOYAGE),
            last: from,
            amount: amount,
            acc: 0,
            unalloc: 0
        }));
        ids.push(id);
        voyageFees += msg.value;
        emit Chartered(id, berth, msg.sender, token, amount, voyages);
    }

    /// After a charter ends, the part streamed while its berth was empty goes back to the charterer (claimToken).
    function reclaimCharter(uint256 id) external nonReentrant {
        Charter storage C = charters[id];
        if (block.timestamp < C.until) revert NotEnded();
        _update(C.berth);
        uint256 u = C.unalloc;
        C.unalloc = 0;
        tokenOwed[C.charterer][C.token] += u;
    }

    function claimToken(address token) external nonReentrant {
        uint256 a = tokenOwed[msg.sender][token];
        tokenOwed[msg.sender][token] = 0;
        if (a > 0) {
            if (!_safeTransfer(token, msg.sender, a)) revert SendFailed();
            emit TokenClaimed(msg.sender, token, a);
        }
    }

    function charteredNow() public view returns (uint256 n) {
        for (uint256 t; t < BERTHS; t++) {
            uint256[] storage ids = berthCharters[t];
            if (ids.length > 0 && charters[ids[ids.length - 1]].until > block.timestamp) n++;
        }
    }

    function chartersOf(uint256 berth) external view returns (uint256[] memory) {
        return berthCharters[berth];
    }

    // ---------- fees + real yield ----------

    /// Push charter and bill fees: 35% BEM-OKB POL / 35% team / 15% burner / 15% reserve. Anyone.
    function sweepVoyageFees() external nonReentrant {
        if (team == address(0)) revert NotWired();
        uint256 f = voyageFees;
        if (f == 0) return;
        voyageFees = 0;
        uint256 b = f * FEE_BEM_BPS / 10_000;
        uint256 t = f * FEE_TEAM_BPS / 10_000;
        uint256 u = f * FEE_BURN_BPS / 10_000;
        _send(bemPol, b);
        _send(team, t);
        _send(burner, u);
        _send(reserve, f - b - t - u);
        emit VoyageFeesSwept(f);
    }

    /// OKB for Cargo rigs (CargoPol Y30 flows, or anyone). It and any unstreamed rest stream over the next 24h.
    /// Review R3-M1: below MIN_RESTREAM, OKB joins the running stream and keeps its end (no free 24h delay griefing).
    function notifyOkb() public payable {
        _updateOkb();
        uint256 left = okbEnd > block.timestamp ? okbEnd - block.timestamp : 0;
        uint256 v = msg.value + unallocatedOkb + left * okbRateX / ACC;
        unallocatedOkb = 0;
        if (left > 0 && msg.value < MIN_RESTREAM) {
            okbRateX = v * ACC / left;
        } else {
            okbRateX = v * ACC / OKB_STREAM;
            okbEnd = uint64(block.timestamp + OKB_STREAM);
        }
        emit OkbNotified(msg.sender, msg.value);
    }

    receive() external payable {
        notifyOkb();
    }

    // ---------- views ----------

    function rigCount() external view returns (uint256) {
        return rigs.length;
    }

    function chartersCount() external view returns (uint256) {
        return charters.length;
    }

    function dockFeeFor(address cpu, uint256 id) external view returns (uint256) {
        (uint256 p,) = powerOf(cpu, id);
        return p * DOCK_FEE_BPS / 10_000;
    }

    /// CARGO budget per berth per voyage right now.
    function berthBudget() external view returns (uint256) {
        uint256 t = block.timestamp < start ? start : block.timestamp;
        return (emittedUntil(t + VOYAGE) - emittedUntil(t)) / SHARES;
    }

    /// CARGO earned (berths + sold Express blocks) but not claimed yet. CargoReserve counts it as supply.
    function unclaimed() external view returns (uint256 u) {
        u = booked;
        for (uint256 t; t < BERTHS; t++) {
            Berth storage B = berths[t];
            if (B.power > 0 && block.timestamp > B.last) u += _budget(B.last, block.timestamp);
        }
        u = u > totalMinted ? u - totalMinted : 0;
    }

    /// Pending CARGO (berth) and OKB (Y30) of a rig. Charter tokens: tokenOwed after claim/sync.
    function pending(uint256 r) external view returns (uint256 c, uint256 o) {
        Rig storage R = rigs[r];
        if (R.owner == address(0)) return (0, 0);
        Berth storage B = berths[R.berth];
        uint256 acc = B.acc;
        if (B.power > 0 && block.timestamp > B.last) {
            acc += _budget(B.last, block.timestamp) * ACC / B.power;
        }
        c = R.power * acc / ACC - R.cargoDebt;
        if (R.season == OFFICIAL) return (c, 0);
        (uint256 a,) = _okbAcc();
        o = R.power * a / ACC - R.okbDebt;
    }

    // ---------- internal ----------

    /// Y30 accumulator up to now, and OKB streamed while no Cargo rig was loaded.
    function _okbAcc() private view returns (uint256 a, uint256 idle) {
        a = accOkb;
        uint256 t = block.timestamp < okbEnd ? block.timestamp : okbEnd;
        if (t <= okbLast) return (a, 0);
        uint256 x = (t - okbLast) * okbRateX;
        uint256 cp = totalPower - officialPower;
        if (cp > 0) a += x / cp;
        else idle = x / ACC;
    }

    function _updateOkb() private {
        (uint256 a, uint256 idle) = _okbAcc();
        accOkb = a;
        unallocatedOkb += idle;
        okbLast = uint64(block.timestamp);
    }

    function _budget(uint256 a, uint256 b) private view returns (uint256) {
        return (emittedUntil(b) - emittedUntil(a)) / SHARES;
    }

    function _update(uint256 t) private {
        Berth storage B = berths[t];
        _updateCharter(t, B.power);
        if (block.timestamp <= B.last) return;
        if (B.power > 0) {
            uint256 b = _budget(B.last, block.timestamp);
            B.acc += b * ACC / B.power;
            booked += b;
        }
        B.last = uint64(block.timestamp);
    }

    /// Stream the berth's latest charter up to now (or its end) at the berth's current power.
    function _updateCharter(uint256 t, uint256 power) private {
        uint256[] storage ids = berthCharters[t];
        uint256 n = ids.length;
        if (n == 0) return;
        Charter storage C = charters[ids[n - 1]];
        uint256 to = block.timestamp < C.until ? block.timestamp : C.until;
        if (to <= C.last) return;
        uint256 dur = C.until - C.from;
        uint256 rel = C.amount * (to - C.from) / dur - C.amount * (C.last - C.from) / dur;
        if (power > 0) C.acc += rel * XACC / power;
        else C.unalloc += rel;
        C.last = uint64(to);
    }

    /// Rig enters a berth: owes nothing on the berth's current charter so far.
    function _joinCharters(Rig storage R) private {
        uint256 n = berthCharters[R.berth].length;
        if (n == 0) {
            (R.cIdx, R.xDebt) = (0, 0);
        } else {
            R.cIdx = uint32(n - 1);
            R.xDebt = UniV3Lib.mulDiv(R.power, charters[berthCharters[R.berth][n - 1]].acc, XACC);
        }
    }

    /// Credit charter tokens the rig earned on its berth (berth must be updated first).
    function _settleCharters(Rig storage R, uint256 maxSteps) private {
        uint256[] storage ids = berthCharters[R.berth];
        uint256 n = ids.length;
        if (n == 0 || maxSteps == 0) return;
        uint256 k = R.cIdx;
        uint256 end = maxSteps < n - k ? k + maxSteps : n;
        uint256 a;
        for (; k < end; k++) {
            Charter storage C = charters[ids[k]];
            a = UniV3Lib.mulDiv(R.power, C.acc, XACC);
            uint256 e = a - (k == R.cIdx ? R.xDebt : 0);
            if (e > 0) tokenOwed[R.owner][C.token] += e;
        }
        if (end == n) (R.cIdx, R.xDebt) = (uint32(n - 1), a);
        else (R.cIdx, R.xDebt) = (uint32(end), 0);
    }

    function _claim(uint256 r) private {
        Rig storage R = rigs[r];
        _updateOkb();
        _update(R.berth);
        _settleCharters(R, type(uint256).max);
        uint256 accC = R.power * berths[R.berth].acc / ACC;
        uint256 accO = R.season == OFFICIAL ? 0 : R.power * accOkb / ACC;
        uint256 c = accC - R.cargoDebt;
        uint256 o = accO - R.okbDebt;
        R.cargoDebt = accC;
        R.okbDebt = accO;
        if (c > 0) {
            totalMinted += c;
            cargo.mint(R.owner, c);
        }
        if (o > 0) _send(R.owner, o);
        if (c > 0 || o > 0) emit Claimed(r, R.owner, c, o);
    }

    function _send(address to, uint256 v) private {
        if (v == 0) return;
        (bool ok,) = to.call{value: v}("");
        if (!ok) revert SendFailed();
    }

    function _safeTransfer(address token, address to, uint256 a) private returns (bool) {
        (bool ok, bytes memory d) = token.call(abi.encodeCall(IERC20Charter.transfer, (to, a)));
        return ok && (d.length == 0 || abi.decode(d, (bool)));
    }

    function _safeTransferFrom(address token, address from, uint256 a) private {
        (bool ok, bytes memory d) = token.call(abi.encodeCall(IERC20Charter.transferFrom, (from, address(this), a)));
        if (!ok || (d.length > 0 && !abi.decode(d, (bool)))) revert BadCharter();
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
