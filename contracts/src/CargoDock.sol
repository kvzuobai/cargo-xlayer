// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// CargoDock (X Layer). Creator of every Cargo season processor on the TapeOut factory, so all transistor
// mint OKB is owed to this contract. sweep() pulls it and splits it on-chain; nothing stays here.
//   Mint split:  10% team · 10% reserve · BEM-OKB POL 35% (+5 pts per season, cap 50%) · CARGO-OKB POL the rest.
//   Dock fee (paid by the miner at rig stake): 45% CARGO buy & burn · 45% BEM-OKB POL · 10% team.
// Season rules are hard-coded: >= 30 days apart, price >= last x 1.25. Owner can only open seasons and wire sinks once.

interface IFactory {
    function createCPU(string calldata, string calldata, string calldata, uint256 supplyCap, uint256 mintPrice)
        external
        payable;
    function deployFee() external view returns (uint256);
    function cpuCount() external view returns (uint256);
    function cpuAt(uint256) external view returns (address);
}

interface ICircuits {
    function transistorsContract() external view returns (address);
}

interface ITransistors {
    function withdraw() external;
    function owed(address) external view returns (uint256);
}

contract CargoDock {
    uint256 public constant SEASON_GAP = 30 days;
    uint256 public constant PRICE_STEP_BPS = 12_500; // x1.25
    uint256 public constant TEAM_BPS = 1_000;
    uint256 public constant RESERVE_BPS = 1_000;
    uint256 public constant BEM_START_BPS = 3_500;
    uint256 public constant BEM_STEP_BPS = 500;
    uint256 public constant BEM_MAX_BPS = 5_000;
    uint256 public constant FEE_BURN_BPS = 4_500;
    uint256 public constant FEE_BEM_BPS = 4_500;

    IFactory public immutable factory;
    address public immutable team;
    address public owner;
    address public pendingOwner; // 2-step hand-over: a typo can't lock season opening forever

    // sinks, wired once (contracts deployed after the dock)
    address public cargoPol;
    address public bemPol;
    address public reserve;
    address public burner;

    struct Season { address cpu; address transistors; uint128 price; uint64 cap; uint64 start; }
    Season[] public seasons;
    mapping(address => uint256) public seasonOf; // cpu => index + 1 (0 = not a Cargo processor)

    uint256 public totalMintOkb;
    uint256 public totalDockFeeOkb;

    event SinksSet(address cargoPol, address bemPol, address reserve, address burner);
    event SeasonOpened(uint256 indexed season, address cpu, address transistors, uint256 price, uint256 cap);
    event Swept(uint256 indexed season, uint256 okb, uint256 team, uint256 reserve, uint256 bemPol, uint256 cargoPol);
    event DockFee(address indexed from, uint256 okb, uint256 burn, uint256 bemPol, uint256 team);
    event OwnerChanged(address owner);

    error NotOwner();
    error AlreadySet();
    error NotWired();
    error TooSoon();
    error PriceTooLow();
    error BadSeason();
    error SendFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address factory_, address team_, address owner_) {
        factory = IFactory(factory_);
        team = team_;
        owner = owner_;
    }

    function setOwner(address o) external onlyOwner {
        pendingOwner = o;
    }

    function acceptOwner() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnerChanged(msg.sender);
    }

    function setSinks(address cargoPol_, address bemPol_, address reserve_, address burner_) external onlyOwner {
        if (cargoPol != address(0)) revert AlreadySet();
        if (cargoPol_ == address(0) || bemPol_ == address(0) || reserve_ == address(0) || burner_ == address(0)) {
            revert NotWired();
        }
        (cargoPol, bemPol, reserve, burner) = (cargoPol_, bemPol_, reserve_, burner_);
        emit SinksSet(cargoPol_, bemPol_, reserve_, burner_);
    }

    /// Opens the next season processor. msg.value must cover factory.deployFee().
    function openSeason(string calldata name, string calldata symbol, string calldata story, uint256 price, uint256 cap)
        external
        payable
        onlyOwner
        returns (address cpu)
    {
        if (cargoPol == address(0)) revert NotWired();
        uint256 n = seasons.length;
        if (n > 0) {
            Season memory last = seasons[n - 1];
            if (block.timestamp < last.start + SEASON_GAP) revert TooSoon();
            if (price * 10_000 < uint256(last.price) * PRICE_STEP_BPS) revert PriceTooLow();
        }
        factory.createCPU{value: msg.value}(name, symbol, story, cap, price);
        cpu = factory.cpuAt(factory.cpuCount() - 1);
        address tr = ICircuits(cpu).transistorsContract();
        seasons.push(Season(cpu, tr, uint128(price), uint64(cap), uint64(block.timestamp)));
        seasonOf[cpu] = n + 1;
        emit SeasonOpened(n, cpu, tr, price, cap);
    }

    function seasonCount() external view returns (uint256) {
        return seasons.length;
    }

    function isCargoCpu(address cpu) external view returns (bool) {
        return seasonOf[cpu] != 0;
    }

    function bemBps(uint256 season) public pure returns (uint256 b) {
        b = BEM_START_BPS + season * BEM_STEP_BPS;
        if (b > BEM_MAX_BPS) b = BEM_MAX_BPS;
    }

    function pending(uint256 season) external view returns (uint256) {
        return ITransistors(seasons[season].transistors).owed(address(this));
    }

    /// Permissionless: pulls mint OKB of one season and splits it.
    function sweep(uint256 season) external returns (uint256 okb) {
        if (season >= seasons.length) revert BadSeason();
        ITransistors tr = ITransistors(seasons[season].transistors);
        if (tr.owed(address(this)) == 0) return 0; // TapeOut withdraw() reverts on zero
        uint256 before = address(this).balance;
        tr.withdraw();
        okb = address(this).balance - before;
        if (okb == 0) return 0;
        totalMintOkb += okb;
        uint256 t = okb * TEAM_BPS / 10_000;
        uint256 r = okb * RESERVE_BPS / 10_000;
        uint256 b = okb * bemBps(season) / 10_000;
        uint256 c = okb - t - r - b;
        _send(team, t);
        _send(reserve, r);
        _send(bemPol, b);
        _send(cargoPol, c);
        emit Swept(season, okb, t, r, b, c);
    }

    /// Dock fee from the miner (or anyone). Split immediately.
    function payDockFee() external payable {
        if (cargoPol == address(0)) revert NotWired();
        uint256 v = msg.value;
        totalDockFeeOkb += v;
        uint256 burn = v * FEE_BURN_BPS / 10_000;
        uint256 bem = v * FEE_BEM_BPS / 10_000;
        uint256 t = v - burn - bem;
        _send(burner, burn);
        _send(bemPol, bem);
        _send(team, t);
        emit DockFee(msg.sender, v, burn, bem, t);
    }

    /// Only the season transistor contracts pay in via withdraw(); stray OKB is refused.
    receive() external payable {
        for (uint256 i = seasons.length; i > 0; i--) {
            if (msg.sender == seasons[i - 1].transistors) return;
        }
        revert();
    }

    function _send(address to, uint256 v) private {
        if (v == 0) return;
        (bool ok,) = to.call{value: v}("");
        if (!ok) revert SendFailed();
    }
}
