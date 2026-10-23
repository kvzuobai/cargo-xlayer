// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// forge test --match-contract RigVoucherFork --fork-url https://rpc.xlayer.tech -vv
// Question: a "TapeOut Rig" voucher (BSC BEM rig locked in the BSC vault) parked in a Cargo-like
// contract: who receives the BEM that the BSC harvest bridges to X Layer?

import "forge-std/Test.sol";

interface IVoucher {
    function ownerOf(uint256) external view returns (address);
    function transferFrom(address, address, uint256) external;
    function marksOf(uint256) external view returns (uint256);
    function holderAt(uint256, uint256) external view returns (address);
    function payeeAt(uint256, uint256) external view returns (address);
    function powerHeld(address) external view returns (uint256);
    function rigs(uint256) external view returns (address circuits, uint64 syncedAt, uint256 circuitId, uint256 power);
    function parked(uint256) external view returns (uint256);
    function vault() external view returns (address);
    function endpoint() external view returns (address);
    function lzCompose(address, bytes32, bytes calldata, address, bytes calldata) external payable;
}

interface IERC20b {
    function balanceOf(address) external view returns (uint256);
}

contract VoucherBerth {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

contract RigVoucherFork is Test {
    IVoucher constant V = IVoucher(0x9cfc959cd42B2e1d39a0d850c528210E818AE520);
    IERC20b constant BEM = IERC20b(0x60e62Efa9405d6873C5deaBD4E6CC91c25363952);
    uint256 constant ID = 1;

    address holder;
    VoucherBerth berth;

    function setUp() public {
        holder = V.ownerOf(ID);
        berth = new VoucherBerth();
    }

    function _park() internal {
        vm.prank(holder);
        V.transferFrom(holder, address(berth), ID);
    }

    function test_V1_parkMovesPayee() public {
        uint256 m0 = V.marksOf(ID);
        uint256 pH0 = V.powerHeld(holder);
        (, uint64 syncedAt,, uint256 power) = V.rigs(ID);
        emit log_named_uint("rig power", power);
        emit log_named_uint("rig syncedAt", syncedAt);
        emit log_named_uint("marks before", m0);
        vm.warp(block.timestamp + 60);
        _park();
        assertEq(V.ownerOf(ID), address(berth));
        uint256 m1 = V.marksOf(ID);
        emit log_named_uint("marks after", m1);
        for (uint256 i = 0; i < m1; i++) {
            emit log_named_address("  holderAt(i)", V.holderAt(ID, i));
        }
        emit log_named_address("payeeAt(now)", V.payeeAt(ID, block.timestamp));
        emit log_named_address("payeeAt(now-120)", V.payeeAt(ID, block.timestamp - 120));
        emit log_named_uint("powerHeld holder before", pH0);
        emit log_named_uint("powerHeld holder after", V.powerHeld(holder));
        emit log_named_uint("powerHeld berth", V.powerHeld(address(berth)));
        assertEq(V.payeeAt(ID, block.timestamp), address(berth));
    }

    // Simulated harvest arrival: endpoint delivers an OFT compose from the BSC vault.
    // Message layout (OFTComposeMsgCodec): nonce(8) srcEid(4) amountLD(32) composeFrom(32) appMsg.
    // appMsg layout read from the voucher impl bytecode (lzCompose -> kind byte -> harvest branch).
    function test_V2_harvestAfterParkPaysBerth() public {
        _park();
        vm.warp(block.timestamp + 3600);
        (uint256 toBerth, uint256 toHolder) = _compose(uint64(block.timestamp));
        assertEq(toBerth, 10e8);
        assertEq(toHolder, 0);
    }

    // Harvest stamped before the park (BSC harvest time < park time) still pays the old holder.
    function test_V3_harvestStampedBeforeParkPaysOldHolder() public {
        uint64 t0 = uint64(block.timestamp);
        vm.warp(block.timestamp + 60);
        _park();
        vm.warp(block.timestamp + 3600);
        (uint256 toBerth, uint256 toHolder) = _compose(t0);
        assertEq(toBerth, 0);
        assertEq(toHolder, 10e8);
    }

    function _compose(uint64 harvestTime) internal returns (uint256 toBerth, uint256 toHolder) {
        uint256 amt = 10e8; // BEM on X Layer has 8 decimals
        deal(address(BEM), address(V), BEM.balanceOf(address(V)) + amt);
        uint256[] memory ids = new uint256[](1);
        ids[0] = ID;
        uint256[] memory packed = new uint256[](1);
        (,,, uint256 power) = V.rigs(ID);
        packed[0] = (amt << 128) | power; // high 128 = BEM, low 128 = BSC hashrate (decoded from bytecode)
        // appMsg kind 2 = harvest: (uint8 kind, uint64 harvestTime, address caller, uint256 bond, ids[], packed[])
        bytes memory app = abi.encode(uint8(2), harvestTime, address(this), uint256(0), ids, packed);
        bytes memory msg_ = abi.encodePacked(uint64(1), uint32(30102), amt, bytes32(uint256(uint160(V.vault()))), app);
        uint256 b0 = BEM.balanceOf(address(berth));
        uint256 h0 = BEM.balanceOf(holder);
        vm.prank(V.endpoint());
        (bool ok, bytes memory err) = address(V).call(
            abi.encodeWithSelector(IVoucher.lzCompose.selector, address(BEM), bytes32(uint256(1)), msg_, address(0), bytes(""))
        );
        emit log_named_string("lzCompose", ok ? "OK" : "REVERT");
        if (!ok) emit log_named_bytes("err", err);
        toBerth = BEM.balanceOf(address(berth)) - b0;
        toHolder = BEM.balanceOf(holder) - h0;
        emit log_named_decimal_uint("BEM berth delta ", toBerth, 8);
        emit log_named_decimal_uint("BEM holder delta", toHolder, 8);
        emit log_named_decimal_uint("parked(ID)", V.parked(ID), 8);
    }
}
