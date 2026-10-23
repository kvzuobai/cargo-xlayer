// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// forge test --match-contract ForeignRigFork --fork-url https://rpc.xlayer.tech -vv
// Question: a real FabX FAB-Genisis circuit parked in a Cargo-like contract keeps mining?
// Who receives FAB on claim, and can the parking contract claim/stop/forward it?

import "forge-std/Test.sol";

interface IERC721x {
    function ownerOf(uint256) external view returns (address);
    function transferFrom(address, address, uint256) external;
    function safeTransferFrom(address, address, uint256) external;
}

interface IERC20x {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IPod {
    function minerKey(address, uint256) external view returns (bytes32);
    function pending(bytes32) external view returns (uint256);
    function claim(bytes32) external;
    function stop(bytes32) external;
}

// Minimal stand-in for Cargo: holds the circuit, claims FAB and forwards it to the depositor.
contract MockBerth {
    IPod constant POD = IPod(0x4F6A2312D80753BdAFd35DDB1Bf4BB14C43F8265);
    IERC20x constant FAB = IERC20x(0x72F349B1Eee7833B26f8C81a8410775A4e231ed2);
    mapping(bytes32 => address) public depositor;

    function onERC721Received(address, address from, uint256, bytes calldata) external pure returns (bytes4) {
        from;
        return this.onERC721Received.selector;
    }

    function park(address cpu, uint256 id, address owner_) external {
        depositor[POD.minerKey(cpu, id)] = owner_;
    }

    function claimAndForward(bytes32 key) external returns (uint256 got) {
        uint256 b = FAB.balanceOf(address(this));
        POD.claim(key);
        got = FAB.balanceOf(address(this)) - b;
        if (got > 0) FAB.transfer(depositor[key], got);
    }

    function stopRig(bytes32 key) external {
        POD.stop(key);
    }

    function giveBack(address cpu, uint256 id, address to) external {
        IERC721x(cpu).transferFrom(address(this), to, id);
    }
}

contract ForeignRigFork is Test {
    address constant CPU = 0x87BFCa3494Aa228fF589ab9B642143A5e8c8F9a6; // FAB-Genisis circuits
    IPod constant POD = IPod(0x4F6A2312D80753BdAFd35DDB1Bf4BB14C43F8265);
    IERC20x constant FAB = IERC20x(0x72F349B1Eee7833B26f8C81a8410775A4e231ed2);
    uint256 constant ID = 6150; // active verified miner (166 NAND + 19 LATCH)

    address holder;
    bytes32 key;
    MockBerth berth;
    address stranger = address(0xBEEF);

    function setUp() public {
        holder = IERC721x(CPU).ownerOf(ID);
        key = POD.minerKey(CPU, ID);
        berth = new MockBerth();
    }

    function _miner() internal view returns (bytes memory) {
        (bool ok, bytes memory r) = address(POD).staticcall(abi.encodeWithSelector(0x0527edc2, key));
        require(ok, "getMiner");
        return r;
    }

    function _logMiner(string memory tag) internal {
        bytes memory r = _miner();
        emit log_string(tag);
        for (uint256 i = 0; i < r.length / 32 && i < 12; i++) {
            uint256 w;
            assembly { w := mload(add(r, add(32, mul(i, 32)))) }
            emit log_named_uint("  word", w);
        }
    }

    function _bal(string memory tag) internal {
        emit log_string(tag);
        emit log_named_decimal_uint("  FAB holder ", FAB.balanceOf(holder), 8);
        emit log_named_decimal_uint("  FAB berth  ", FAB.balanceOf(address(berth)), 8);
        emit log_named_decimal_uint("  FAB stranger", FAB.balanceOf(stranger), 8);
        emit log_named_decimal_uint("  pending    ", POD.pending(key), 8);
    }

    // A: baseline, no transfer. A stranger triggers claim: FAB goes to the holder.
    function test_A_claimByStrangerPaysHolder() public {
        emit log_named_address("holder", holder);
        emit log_named_uint("holder codesize", holder.code.length);
        _logMiner("getMiner words");
        // note: pending(key) is a stale view (last checkpoint), so measure real claim deltas
        vm.warp(block.timestamp + 1 days);
        uint256 h0 = FAB.balanceOf(holder);
        vm.prank(stranger);
        POD.claim(key);
        _bal("A after stranger claim");
        assertGt(FAB.balanceOf(holder) - h0, 0, "holder got nothing");
        assertEq(FAB.balanceOf(stranger), 0);
    }

    // B: park in berth. Pending accrued BEFORE the transfer + after it: who is paid?
    function test_B_parkedCircuitPaysWho() public {
        vm.warp(block.timestamp + 1 days);
        uint256 preTransfer = POD.pending(key);
        uint256 h0 = FAB.balanceOf(holder);
        vm.prank(holder);
        IERC721x(CPU).transferFrom(holder, address(berth), ID);
        berth.park(CPU, ID, holder);
        assertEq(IERC721x(CPU).ownerOf(ID), address(berth));
        emit log_named_decimal_uint("pending at transfer", preTransfer, 8);
        emit log_named_decimal_uint("pending right after transfer", POD.pending(key), 8);
        _logMiner("getMiner after transfer");

        // Still mining while parked?
        vm.warp(block.timestamp + 1 days);
        uint256 afterDay = POD.pending(key);
        emit log_named_decimal_uint("pending after 1 more day parked", afterDay, 8);

        // Stranger claims: who gets it?
        vm.prank(stranger);
        POD.claim(key);
        _bal("B after stranger claim (parked)");
        emit log_named_decimal_uint("holder delta", FAB.balanceOf(holder) - h0, 8);
        assertEq(FAB.balanceOf(holder), h0, "old holder paid");
        assertGt(FAB.balanceOf(address(berth)), preTransfer, "berth got pre-transfer accrual + parked day");
    }

    // C: berth claims and forwards to depositor (Cargo forward path).
    function test_C_berthClaimsAndForwards() public {
        vm.prank(holder);
        IERC721x(CPU).transferFrom(holder, address(berth), ID);
        berth.park(CPU, ID, holder);
        uint256 h0 = FAB.balanceOf(holder);
        vm.warp(block.timestamp + 1 days);
        uint256 p = POD.pending(key);
        uint256 got = berth.claimAndForward(key);
        emit log_named_decimal_uint("pending", p, 8);
        emit log_named_decimal_uint("berth received + forwarded", got, 8);
        _bal("C after berth claimAndForward");
        emit log_named_decimal_uint("holder delta", FAB.balanceOf(holder) - h0, 8);
        assertEq(FAB.balanceOf(holder) - h0, got);
        assertEq(FAB.balanceOf(address(berth)), 0);
    }

    // D: old holder cannot stop a parked rig; berth (new holder) can.
    function test_D_stopRights() public {
        vm.prank(holder);
        IERC721x(CPU).transferFrom(holder, address(berth), ID);
        vm.prank(holder);
        (bool okOld,) = address(POD).call(abi.encodeWithSelector(IPod.stop.selector, key));
        emit log_named_string("old holder stop", okOld ? "OK" : "REVERT");
        (bool okBerth, bytes memory err) = address(berth).call(abi.encodeWithSelector(MockBerth.stopRig.selector, key));
        emit log_named_string("berth stop", okBerth ? "OK" : "REVERT");
        if (!okBerth) emit log_named_bytes("berth stop err", err);
        assertFalse(okOld);
        assertTrue(okBerth);
    }

    // E: return the circuit: does mining continue for the depositor afterwards?
    function test_E_returnAfterPark() public {
        vm.prank(holder);
        IERC721x(CPU).transferFrom(holder, address(berth), ID);
        berth.park(CPU, ID, holder);
        vm.warp(block.timestamp + 1 days);
        berth.claimAndForward(key);
        berth.giveBack(CPU, ID, holder);
        assertEq(IERC721x(CPU).ownerOf(ID), holder);
        vm.warp(block.timestamp + 1 days);
        uint256 h0 = FAB.balanceOf(holder);
        vm.prank(holder);
        POD.claim(key);
        emit log_named_decimal_uint("FAB 1 day after return", FAB.balanceOf(holder) - h0, 8);
        assertGt(FAB.balanceOf(holder) - h0, 0, "stopped mining after return");
    }
}
