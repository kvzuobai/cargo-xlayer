# Cargo

A ship on X Layer, built on [TapeOut](https://tapeout.net). Mint transistors on Cargo's season processor, tape out a circuit, load it onto one of 25 berths. Every 5-minute voyage, CARGO is split across loaded berths by circuit power. The OKB users pay is split by fixed rules into locked liquidity, a redemption reserve, buy-and-burn and the team.

- Live app (X Layer DeWEB): https://1-2-387.tapekit.org/
- How Cargo works (EN / 中文): https://1-2-387.tapekit.org/#docs
- Built for OKX Xccelerate × TapeOut (X Layer)

> Experimental and unaudited. Cargo contracts are not upgradable; fee-route changes wait 48h. TapeOut circuit contracts are upgradable by the TapeOut team. Use only what you can lose. Nothing here is a price promise.

## Contracts (X Layer mainnet, chain 196)

| Contract | Address |
|---|---|
| CargoToken (CARGO) | `0x72619E6e288D09d94aB830276D5B3AD3D7227231` |
| CargoDock | `0xFEb6646376087ac01b47d6cbf6597e0403A87b39` |
| CargoMiner (bills of lading, CBOL) | `0x98578A7442A2438B6E68500891CCafd70d286FF3` |
| Season 1 processor (TapeOut CPU) | `0x192e074521A6EF0DA110E08A9d78561D1b2C7F55` |
| Season 1 transistors | `0x65bA1348E29C3CC02c1870efc56207DAbf0E61eE` |
| CargoPol CARGO-OKB | `0xa16F7dF8347465EA5eD9765bae92419cdD69e339` |
| CargoPol BEM-OKB | `0xFd52D644F4Cf1bFa1512fbC9a5B413c48613F083` |
| CargoBurner | `0xE5506123DE830dCbACCeaEa144B79dB75054473F` |
| CargoReserve | `0x44c3DFAB564c2F1b1aaB82679584B3112BA9a46a` |

## How it works

1. **Mint NAND** on the Cargo season processor (Season 1: 0.002 OKB per NAND, cap 2,000,000).
2. **Tape out** a circuit on TapeOut.
3. **Load** it onto one of 25 berths, paying a 5% dock fee. Power = transistors burned in the circuit × season price.

Emission is 5,000 CARGO per day (max 10,000,000, no premine, no team allocation), split into 29 equal shares: 25 berths + 4 for hourly Express blocks. Each berth's share is split by power among its circuits; empty berths mint nothing.

| OKB flow | Team | BEM-OKB LP | CARGO-OKB LP | Buy & burn CARGO | Reserve | Circuits |
|---|---|---|---|---|---|---|
| Transistor mint | 10% | 35%* | 45%* | — | 10% | — |
| Dock fee (5%) | 10% | 45% | — | 45% | — | — |
| Voyage fees (charters + 1% bill sales) | 35% | 35% | — | 15% | 15% | — |
| CARGO-OKB pool fees | — | — | — | 70% | — | 30% |

\* Season 1. The BEM-OKB share grows 5 points each season (max 50%). Liquidity positions are held by contracts with no remove function.

- **Express**: buy a seat for the next hour with CARGO (burned); seat holders share 4/29 of emission by power.
- **Charter**: a project rents a berth for 7–90 days (0.0005 OKB per voyage) and streams its own token to the circuits there.
- **Bills of lading**: each loaded circuit is an NFT, tradable only in the built-in market (1% fee).
- **Reserve**: redeem CARGO for a pro-rata share of free OKB (1% fee, 24h delay). Not a floor.
- **Admin powers**: re-point fee destinations / oracle (48h timelock, shown on the site), add official TapeOut CPUs (48h, max 20), remove them (blocks new loads only), open a new season (≥30 days, price ≥ ×1.25). No upgrade, pause, extra mint, or access to user circuits, the reserve or pool liquidity.

## Repository

| Path | What |
|---|---|
| `contracts/` | Foundry project for the deployed v2 contracts (`src/`), unit + fork tests (`test/`), deploy script (`script/`) |
| `site/` | The app (single `index.html`, reads every number from the contracts) |
| `keeper/` | Permissionless maintenance bot (sweep, add liquidity, harvest, burn) + admin-event alerts and daily on-chain report |
| `sim/` | Economic simulations used for the design |
| `season2/` | **Not deployed.** Season 2 candidate: Proof of Design (`CargoDesign.sol`), berth-move fee in CARGO, updated Miner, tests, site |
| `tools/` | Local static server and UI end-to-end script |

### Build and test

```bash
cd contracts
forge install foundry-rs/forge-std --no-git
forge test --no-match-contract Fork
forge test --match-contract Fork --fork-url https://rpc.xlayer.tech
```

`CargoMiner.sol` is compiled with via-IR (set in `foundry.toml`).

### Run the site locally

```bash
node tools/serve.js
```

Open http://localhost:5190/ (reads X Layer mainnet; `?rpc=<url>` to use another RPC).

### Keeper

```bash
npm install
node keeper/cargo-keeper.js status
```

`run` / `loop` need `KEEPER_PK` in the environment (never commit it). Optional `TG_TOKEN` / `TG_CHAT` send admin-event alerts and a daily report to Telegram.

## Season 2 preview: Proof of Design

Season 1 power is capital: transistors × price. Season 2 adds design power. A job is a reference TapeOut circuit; its full truth table is read on-chain with TapeOut `eval`. Anyone can certify a Cargo circuit for a job if it gives the same outputs for every input (no state, no REF). Certified circuits earn bonus power `B = K × clamp(K/C, 1/4, 2) / 2` (K = reference NAND, C = circuit NAND). B does not grow with C, so padding adds no design power; a design twice as efficient as the reference earns 3× the power per OKB of transistors, which is also the cap (B ≤ 2C). Fees and burns stay on transistor value. See `season2/`.

## License

MIT
