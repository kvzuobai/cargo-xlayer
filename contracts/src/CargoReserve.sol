// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// Cargo redemption reserve (F10). Holds OKB; any holder can burn CARGO for a pro-rata share:
//   payout = free OKB x amount / CARGO totalSupply (before burn), minus 1% fee that stays in the reserve.
//   Pro-rata redeem never lowers the floor for the remaining holders (s36 check), so no market cap is needed.
//   Supply = CARGO totalSupply + CARGO earned in the miner but not claimed yet (else the first claimer takes all).
// CARGO is burned at request; OKB is claimable after a 24h cool-down. No owner, no withdraw path.

interface ICargo {
    function totalSupply() external view returns (uint256);
    function burnFrom(address, uint256) external;
}

interface IMinerSupply {
    function unclaimed() external view returns (uint256);
}

contract CargoReserve {
    uint256 public constant FEE_BPS = 100;
    uint256 public constant COOLDOWN = 24 hours;

    ICargo public immutable cargo;
    IMinerSupply public immutable miner;

    struct Request { uint128 okb; uint64 readyAt; }
    mapping(address => Request[]) public requests;
    uint256 public totalOwed; // OKB promised to pending requests

    event Funded(address indexed from, uint256 okb);
    event Redeem(address indexed user, uint256 cargo, uint256 okb, uint256 readyAt);
    event Claim(address indexed user, uint256 okb);

    error Zero();
    error NotReady();
    error SendFailed();

    uint256 private lock = 1;
    modifier nonReentrant() {
        require(lock == 1);
        lock = 2;
        _;
        lock = 1;
    }

    constructor(address cargo_, address miner_) {
        cargo = ICargo(cargo_);
        miner = IMinerSupply(miner_);
    }

    /// CARGO the reserve is shared by: circulating + earned-but-unclaimed.
    function supply() public view returns (uint256) {
        return cargo.totalSupply() + miner.unclaimed();
    }

    receive() external payable {
        emit Funded(msg.sender, msg.value);
    }

    function freeOkb() public view returns (uint256) {
        return address(this).balance - totalOwed;
    }

    /// OKB per 1 CARGO (1e18) right now, before fee — the hard floor shown in the UI.
    function floorPerCargo() external view returns (uint256) {
        uint256 s = supply();
        return s == 0 ? 0 : freeOkb() * 1e18 / s;
    }

    function quote(uint256 amount) public view returns (uint256) {
        uint256 s = supply();
        if (s == 0) return 0;
        uint256 gross = freeOkb() * amount / s;
        return gross - gross * FEE_BPS / 10_000;
    }

    function redeem(uint256 amount) external nonReentrant returns (uint256 okb) {
        okb = quote(amount);
        if (okb == 0) revert Zero();
        cargo.burnFrom(msg.sender, amount);
        totalOwed += okb;
        uint64 readyAt = uint64(block.timestamp + COOLDOWN);
        requests[msg.sender].push(Request(uint128(okb), readyAt));
        emit Redeem(msg.sender, amount, okb, readyAt);
    }

    /// Pays every ready request of the caller.
    function claim() external nonReentrant returns (uint256 paid) {
        Request[] storage r = requests[msg.sender];
        for (uint256 i = r.length; i > 0; i--) {
            Request memory q = r[i - 1];
            if (q.readyAt > block.timestamp) continue;
            paid += q.okb;
            r[i - 1] = r[r.length - 1];
            r.pop();
        }
        if (paid == 0) revert NotReady();
        totalOwed -= paid;
        (bool ok,) = msg.sender.call{value: paid}("");
        if (!ok) revert SendFailed();
        emit Claim(msg.sender, paid);
    }

    function pendingCount(address user) external view returns (uint256) {
        return requests[user].length;
    }
}
