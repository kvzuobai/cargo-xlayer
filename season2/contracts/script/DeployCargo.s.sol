// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {CargoToken} from "../src/CargoToken.sol";
import {CargoDock} from "../src/CargoDock.sol";
import {CargoMiner} from "../src/CargoMiner.sol";
import {CargoDesign} from "../src/CargoDesign.sol";
import {CargoBurner} from "../src/CargoBurner.sol";
import {CargoPol} from "../src/CargoPol.sol";
import {CargoReserve} from "../src/CargoReserve.sol";

interface IUniV3Factory {
    function createPool(address, address, uint24) external returns (address);
}

interface ITapeoutFactory {
    function deployFee() external view returns (uint256);
}

/// FOUNDER-ONLY, NOT RUN BY ENGINEER. Dry-run (gas, no tx):
///   forge script script/DeployCargo.s.sol --fork-url https://rpc.xlayer.tech --sender <founder> -vv
/// Real deploy needs your own signer (--ledger); never put a private key in this repo.
/// env: TEAM (team wallet / ERC-6551 treasury), OWNER (dock owner after wiring), WALLET_CAP_S1 (OKB wei, optional).
/// Deploy right before mint opens (emission starts now). Pool is opened + bootstrapped here with a 0.01 OKB seed
/// (founder OK s36) so nobody can add foreign liquidity first (PoolTaken would brick the set). Then OWNER calls
/// dock.acceptOwner() and design.acceptOwner(). Keeper: dock.sweep, cargoPol.addBid, bemPol.add (after 15 min of BEM TWAP), harvest, burner.burn.
contract DeployCargo is Script {
    address constant TAPEOUT_FACTORY = 0x1f09DAeFA827f02CBb40967cc91b259763760761;
    address constant UNI_FACTORY = 0x4B2ab38DBF28D31D467aA8993f6c2585981D6804;
    address constant NPM = 0x315e413A11AB0df498eF83873012430ca36638Ae;
    address constant ROUTER = 0x4f0C28f5926AFDA16bf2506D5D9e57Ea190f9bcA;
    address constant WOKB = 0xe538905cf8410324e03A5A23C1c177a474D59b2b;
    address constant BEM_POOL = 0x2CcF8aa17F5DF9Fb5D51C9de12135a913fF29f7A;
    uint24 constant FEE = 10_000;
    uint256 constant P0_CARGO_PER_OKB = 20_000; // P0 = 0.00005 OKB (hype-sim, s35)
    uint256 constant S1_PRICE = 0.002 ether;
    uint256 constant S1_CAP = 2_000_000;
    uint256 constant SEED = 0.01 ether; // first buy range; mint OKB joins it via addBid

    struct Cargo {
        CargoToken token;
        CargoDock dock;
        CargoMiner miner;
        CargoDesign design;
        CargoBurner burner;
        CargoPol cargoPol;
        CargoPol bemPol;
        CargoReserve reserve;
        address cpu; // season 1 processor
    }

    function run() external returns (Cargo memory c) {
        address team = vm.envAddress("TEAM");
        address owner = vm.envAddress("OWNER");
        uint256 cap = vm.envOr("WALLET_CAP_S1", uint256(1 ether));
        vm.startBroadcast();
        (, address self,) = vm.readCallers();
        c = deploy(self, team, owner, cap);
        vm.stopBroadcast();
        console2.log("CargoToken  ", address(c.token));
        console2.log("CargoDock   ", address(c.dock));
        console2.log("CargoMiner  ", address(c.miner));
        console2.log("CargoDesign ", address(c.design));
        console2.log("CargoBurner ", address(c.burner));
        console2.log("CargoPol    ", address(c.cargoPol));
        console2.log("BemPol      ", address(c.bemPol));
        console2.log("CargoReserve", address(c.reserve));
        console2.log("S1 CPU      ", c.cpu);
    }

    /// Full wiring in deploy order. `self` = the address that sends these calls (broadcaster, or this contract in tests).
    /// Needs factory.deployFee() + SEED OKB.
    function deploy(address self, address team, address owner, uint256 walletCapS1) public payable returns (Cargo memory c) {
        c.token = new CargoToken();
        c.dock = new CargoDock(TAPEOUT_FACTORY, team, self);
        c.miner = new CargoMiner(address(c.token), address(c.dock), TAPEOUT_FACTORY, owner, block.timestamp, walletCapS1);
        c.design = new CargoDesign(address(c.dock), self); // S2 proof of design; 2-step hand-over below, OWNER accepts
        if (owner != self) c.design.setOwner(owner); // owner must acceptOwner()
        c.miner.setDesign(address(c.design)); // before setOracle/setSinks: they end the deployer role
        c.token.setMinter(address(c.miner));
        address pool = IUniV3Factory(UNI_FACTORY).createPool(address(c.token), WOKB, FEE);
        c.burner = new CargoBurner(pool, ROUTER, WOKB, address(c.token));
        c.miner.setOracle(address(c.burner));
        c.cargoPol = new CargoPol(
            pool, NPM, ROUTER, WOKB, address(c.token), address(c.burner), address(c.miner), sqrtP0(address(c.token))
        );
        c.bemPol = new CargoPol(BEM_POOL, NPM, ROUTER, WOKB, address(c.token), address(c.burner), address(c.miner), 0);
        c.reserve = new CargoReserve(address(c.token), address(c.miner));
        c.dock.setSinks(address(c.cargoPol), address(c.bemPol), address(c.reserve), address(c.burner));
        c.miner.setSinks(address(c.bemPol), address(c.burner), address(c.reserve), team); // voyage fees
        c.bemPol.prepare(200); // BEM/WOKB pool keeps 1 observation; TWAP needs history
        c.cpu = c.dock.openSeason{value: ITapeoutFactory(TAPEOUT_FACTORY).deployFee()}(
            "Cargo S1", "CGO1", "Cargo season 1", S1_PRICE, S1_CAP
        );
        (bool ok,) = address(c.cargoPol).call{value: SEED}("");
        require(ok, "seed");
        c.cargoPol.bootstrap();
        if (owner != self) c.dock.setOwner(owner); // owner must acceptOwner()
    }

    /// sqrt(token1/token0 price) in Q96 for 1 CARGO = 1/P0_CARGO_PER_OKB OKB.
    function sqrtP0(address cargo) public pure returns (uint160) {
        uint256 q192 = uint256(1) << 192;
        return uint160(_sqrt(cargo < WOKB ? q192 / P0_CARGO_PER_OKB : q192 * P0_CARGO_PER_OKB));
    }

    function _sqrt(uint256 x) private pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x;
        uint256 z = (x >> 1) + 1;
        while (z < y) (y, z) = (z, (x / z + z) >> 1);
    }
}
