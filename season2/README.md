# Season 2 candidate (not deployed)

Overlay on `../contracts`: copy `season2/contracts/src`, `test` and `script` over `contracts/` to build and test.

- `CargoDesign.sol` — Proof of Design. Jobs are reference TapeOut circuits (≤ 8 inputs, vectors × gates ≤ 4096, stateless, NAND-only); `queueJob` stores the truth table via TapeOut `eval` and is usable after 48h; `certify(cpu, id, job)` checks every input on-chain; `bonusPower` adds `B × price` to a certified circuit's reward power. The first circuit to reach a new lowest NAND count for a job is recorded as the design record.
- `CargoMiner.sol` — `setDesign()` (deployer, once); `stake()` adds design power to reward power while the 5% dock fee and the Season 2+ CARGO burn stay on transistor value; berth moves limited to every 2 hours and burn CARGO worth 12 voyages of the circuit's share at the new berth.
- `script/DeployCargo.s.sol` — deploys `CargoDesign` and wires it before the deployer role ends.
- Tests: `CargoDesign.t.sol`, `CargoDesignFork.t.sol` (real TapeOut eval on X Layer), `CargoMiner.t.sol`, `CargoMinerInvariant.t.sol`.
- `site/index.html` — app with the Proof of Design panel on the Load tab.
- `berth-bot-sim.js` — simulation of berth-hopping bots vs. normal users under the move fee.

Status: unit + fork tests pass; internal engineering review done (bonus capped at 3x the transistor value, jobs only from Cargo circuits). Not audited.
