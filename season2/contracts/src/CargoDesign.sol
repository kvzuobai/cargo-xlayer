// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// CargoDesign — proof of design for Cargo season circuits (S2).
// A job is a reference TapeOut circuit: its full truth table (all 2^nIn inputs, via TapeOut eval) is stored when queued.
// Anyone can certify a Cargo circuit for a job: it must give the same outputs for every input (checked on-chain with
// eval), use no REF and no state. The Miner then adds design power on top of the capital power:
//   bonus units B = K x clamp(K / C, 1/4, 2) / 2      (K = reference transistors, C = candidate transistors)
// B does not grow with C, so padding a circuit with extra transistors adds capital power only, not design power.
// Same transistors as the reference: +0.5 K. Twice as efficient: +1 K. Capped at B <= 2C: power is never more than 3x
// the transistor value, however small the design (review H1).
// The first circuit to reach a new lowest C for a job is recorded on-chain as the design record (credit only).
// Owner (2-step): queue jobs from Cargo season circuits only (usable after 48h), retire jobs (blocks new certificates
// only). Nothing else.

interface IDesignCircuit {
    function netlist(uint256 id) external view returns (bytes memory);
    function eval(uint256 id, bytes calldata input) external view returns (bytes memory);
    function circuitInfo(uint256 id) external view returns (uint32 nIn, uint32 nOut, uint32 nState, uint32 gateCount);
}

interface IDesignDock {
    function seasonOf(address cpu) external view returns (uint256);
}

contract CargoDesign {
    uint256 public constant MAX_IN = 8; // 256 vectors at most
    uint256 public constant MAX_OUT = 32;
    uint256 public constant MAX_GATES = 256;
    uint256 public constant MAX_WORK = 4096; // vectors x gates: measured with real TapeOut eval, certify <= ~14M gas
    uint256 public constant MAX_JOBS = 64;
    uint256 public constant TIMELOCK = 48 hours;
    uint256 private constant ONE = 1e4; // bonus units scale

    struct Job {
        address refCpu;
        uint64 refId;
        uint8 nIn;
        uint8 nOut;
        uint32 k; // reference transistors
        uint64 readyAt;
        bool retired;
        uint32 bestC; // lowest certified transistor count (0 = none yet)
        address bestCpu;
        uint64 bestId;
        string name;
        bytes expected; // 2^nIn outputs, ceil(nOut/8) bytes each, unused bits zero
    }

    struct Cert {
        uint32 job; // job id + 1 (0 = none)
        uint32 c; // candidate transistors
        uint64 units; // bonus units x 1e4
    }

    IDesignDock public immutable dock;
    address public owner;
    address public pendingOwner;
    Job[] internal jobs;
    mapping(address => mapping(uint256 => Cert)) public certs;

    event JobQueued(uint256 indexed job, string name, address refCpu, uint256 refId, uint256 k, uint256 readyAt);
    event JobRetired(uint256 indexed job);
    event Certified(address indexed cpu, uint256 indexed id, uint256 indexed job, uint256 c, uint256 units);
    event NewRecord(uint256 indexed job, address cpu, uint256 id, uint256 c);
    event OwnerChanged(address owner);

    error NotOwner();
    error BadJob();
    error BadCircuit();
    error BadNetlist();
    error NotReady();
    error WrongOutput(uint256 input);
    error NotBetter();

    constructor(address dock_, address owner_) {
        dock = IDesignDock(dock_);
        owner = owner_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
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

    // ---------- jobs ----------

    /// Queue reference circuit `refId` on TapeOut CPU `refCpu` as a job. Its truth table is read now; usable after 48h.
    function queueJob(string calldata name, address refCpu, uint256 refId) external onlyOwner returns (uint256 j) {
        // the reference must be a real Cargo circuit, so K and the truth table come from TapeOut, not an owner contract (H2)
        if (jobs.length >= MAX_JOBS || refId > type(uint64).max || dock.seasonOf(refCpu) == 0) revert BadJob();
        (uint256 nIn, uint256 nOut, uint256 k) = _shape(refCpu, refId);
        uint256 w = (nOut + 7) / 8;
        bytes memory exp = new bytes(w << nIn);
        for (uint256 x; x < (1 << nIn); x++) {
            bytes memory out = _run(refCpu, refId, x, nIn, nOut);
            for (uint256 b; b < w; b++) exp[x * w + b] = out[b];
        }
        j = jobs.length;
        jobs.push(Job(refCpu, uint64(refId), uint8(nIn), uint8(nOut), uint32(k), uint64(block.timestamp + TIMELOCK), false, 0,
            address(0), 0, name, exp));
        emit JobQueued(j, name, refCpu, refId, k, block.timestamp + TIMELOCK);
    }

    /// Stop new certificates for a job. Existing certificates keep their bonus.
    function retireJob(uint256 j) external onlyOwner {
        if (j >= jobs.length || jobs[j].retired) revert BadJob();
        jobs[j].retired = true;
        emit JobRetired(j);
    }

    // ---------- certify (anyone) ----------

    /// Check Cargo circuit `id` on `cpu` against job `j` for every input. Keeps the higher bonus if already certified.
    function certify(address cpu, uint256 id, uint256 j) external returns (uint256 units) {
        if (j >= jobs.length) revert BadJob();
        Job storage J = jobs[j];
        if (J.retired || block.timestamp < J.readyAt) revert NotReady();
        if (dock.seasonOf(cpu) == 0 || id > type(uint64).max) revert BadCircuit();
        (uint256 nIn, uint256 nOut, uint256 c) = _shape(cpu, id);
        if (nIn != J.nIn || nOut != J.nOut) revert BadCircuit();
        uint256 w = (nOut + 7) / 8;
        bytes memory exp = J.expected;
        for (uint256 x; x < (1 << nIn); x++) {
            bytes memory out = _run(cpu, id, x, nIn, nOut);
            for (uint256 b; b < w; b++) if (out[b] != exp[x * w + b]) revert WrongOutput(x);
        }
        units = bonusUnits(J.k, c);
        Cert storage C = certs[cpu][id];
        if (units <= C.units) revert NotBetter();
        (C.job, C.c, C.units) = (uint32(j + 1), uint32(c), uint64(units));
        emit Certified(cpu, id, j, c, units);
        if (J.bestC == 0 || c < J.bestC) {
            (J.bestC, J.bestCpu, J.bestId) = (uint32(c), cpu, uint64(id));
            emit NewRecord(j, cpu, id, c);
        }
    }

    // ---------- views ----------

    /// B x 1e4 = min(K x clamp(K/C, 1/4, 2) / 2, 2C), in transistor units.
    function bonusUnits(uint256 k, uint256 c) public pure returns (uint256) {
        uint256 r = k * k * ONE / c; // K^2/C x 1e4
        uint256 lo = k * ONE / 4;
        uint256 hi = k * ONE * 2;
        uint256 u = (r < lo ? lo : r > hi ? hi : r) / 2;
        uint256 cap = 2 * c * ONE; // B <= 2C: at most 3x the transistor value (H1)
        return u > cap ? cap : u;
    }

    /// Design power for a circuit whose capital power is `base` (= C x season price): B x price. 0 if not certified.
    function bonusPower(address cpu, uint256 id, uint256 base) external view returns (uint256) {
        Cert memory C = certs[cpu][id];
        if (C.job == 0) return 0;
        return base * C.units / (uint256(C.c) * ONE);
    }

    function jobCount() external view returns (uint256) {
        return jobs.length;
    }

    function job(uint256 j)
        external
        view
        returns (string memory name, address refCpu, uint256 refId, uint256 nIn, uint256 nOut, uint256 k, uint256 readyAt,
            bool retired, uint256 bestC, address bestCpu, uint256 bestId)
    {
        Job storage J = jobs[j];
        return (J.name, J.refCpu, J.refId, J.nIn, J.nOut, J.k, J.readyAt, J.retired, J.bestC, J.bestCpu, J.bestId);
    }

    function expectedOf(uint256 j) external view returns (bytes memory) {
        return jobs[j].expected;
    }

    // ---------- internal ----------

    /// nIn, nOut, transistors of a stateless, REF-free circuit within the size limits.
    function _shape(address cpu, uint256 id) internal view returns (uint256 nIn, uint256 nOut, uint256 c) {
        (uint32 i, uint32 o, uint32 s, uint32 g) = IDesignCircuit(cpu).circuitInfo(id);
        if (i == 0 || i > MAX_IN || o == 0 || o > MAX_OUT || s != 0 || g > MAX_GATES || (uint256(1) << i) * g > MAX_WORK) {
            revert BadCircuit();
        }
        c = nandCount(IDesignCircuit(cpu).netlist(id));
        // bound by the real NAND count too, not only the reported gateCount (H2)
        if (c == 0 || c > MAX_GATES || (uint256(1) << i) * c > MAX_WORK) revert BadCircuit();
        (nIn, nOut) = (i, o);
    }

    /// Outputs of `cpu.eval(id, x)`, length ceil(nOut/8), unused high bits cleared.
    function _run(address cpu, uint256 id, uint256 x, uint256 nIn, uint256 nOut) internal view returns (bytes memory out) {
        bytes memory inp = new bytes((nIn + 7) / 8);
        inp[0] = bytes1(uint8(x));
        out = IDesignCircuit(cpu).eval(id, inp);
        uint256 w = (nOut + 7) / 8;
        if (out.length < w) revert BadCircuit();
        assembly { mstore(out, w) } // ignore any padding bytes
        if (nOut % 8 != 0) out[w - 1] = bytes1(uint8(out[w - 1]) & uint8((1 << (nOut % 8)) - 1));
    }

    /// NAND count of a netlist. LATCH (state) and REF (another circuit's gates) are rejected.
    function nandCount(bytes memory n) public pure returns (uint256 c) {
        uint256 i;
        uint256 len = n.length;
        while (i < len) {
            if (uint8(n[i]) != 0) revert BadNetlist();
            c++;
            i += 7;
        }
        if (i != len) revert BadNetlist();
    }
}
