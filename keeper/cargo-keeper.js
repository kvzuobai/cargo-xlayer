// Cargo keeper (X Layer). Every action is permissionless; the keeper only pays gas. Runbook: docs/cargo-keeper.md
// Usage:
//   node tools/cargo-keeper.js addrs <contracts/broadcast/DeployCargo.s.sol/196/run-latest.json>  -> writes ops/cargo-addresses.json
//   node tools/cargo-keeper.js status          read-only: balances, pending fees, what is due
//   node tools/cargo-keeper.js run             one pass (needs KEEPER_PK; DRY=1 = simulate only, send nothing)
//   node tools/cargo-keeper.js loop            run every INTERVAL_MIN (default 15) + admin alerts + daily report (cargo-watch.js)
//   node tools/cargo-keeper.js watch | report  read-only: check admin events now / send the daily report now
// Env: RPC (default https://rpc.xlayer.tech), KEEPER_PK, ADDRS (default ops/cargo-addresses.json),
//      MIN_OKB (default 0.002) min OKB to sweep/add/burn, MIN_FEE_OKB (default 0.0005) min WOKB fees to harvest,
//      MAX_BURN_OKB (default 0.5) per burn tx, MIN_GAS_OKB (default 0.005) keeper stops below this.
// Rule: every tx is simulated with staticCall first; a revert is logged and skipped, never retried in a loop.

const fs = require("fs");
const path = require("path");
const { ethers } = require("ethers");
const W = require("./cargo-watch");

const RPC = process.env.RPC || "https://rpc.xlayer.tech";
const ADDRS = process.env.ADDRS || path.join(__dirname, "..", "ops", "cargo-addresses.json");
const eth = (k, d) => ethers.parseEther(process.env[k] || d);
const MIN_OKB = eth("MIN_OKB", "0.002");
const MIN_FEE_OKB = eth("MIN_FEE_OKB", "0.0005");
const MAX_BURN_OKB = eth("MAX_BURN_OKB", "0.5");
const MIN_GAS_OKB = eth("MIN_GAS_OKB", "0.005");
const INTERVAL_MIN = +(process.env.INTERVAL_MIN || 15);
const DRY = process.env.DRY === "1";
const CARD = 200; // TWAP history the contracts need (15-min TWAP)

const ERR = ["error PriceMoved()", "error Nothing()", "error NoBootstrap()", "error TooSoon()", "error PoolTaken()"];
const ABI = {
  dock: [
    "function seasonCount() view returns (uint256)",
    "function seasons(uint256) view returns (address cpu, address transistors, uint128 price, uint64 cap, uint64 start)",
    "function sweep(uint256 season) returns (uint256)",
    "function cargoPol() view returns (address)", "function bemPol() view returns (address)",
    "function reserve() view returns (address)", "function burner() view returns (address)",
  ],
  miner: ["function voyageFees() view returns (uint256)", "function sweepVoyageFees()", "error NotWired()"],
  transistors: ["function owed(address) view returns (uint256)"],
  pol: [
    "function add() returns (uint128)", "function addBid() returns (uint128)", "function harvest()",
    "function prepare(uint16)", "function pool() view returns (address)", "function npm() view returns (address)",
    "function wokb() view returns (address)", "function token0() view returns (address)",
    "function tokenId() view returns (uint256)", "function bidIds(uint256) view returns (uint256)",
    "function sqrtP0() view returns (uint160)", ...ERR,
  ],
  burner: ["function burn(uint256 maxIn) returns (uint256)", "function pool() view returns (address)", ...ERR],
  reserve: ["function floorPerCargo() view returns (uint256)", "function freeOkb() view returns (uint256)"],
  pool: ["function slot0() view returns (uint160, int24 tick, uint16, uint16 card, uint16 cardNext, uint8, bool)"],
  npm: ["function collect((uint256 tokenId, address recipient, uint128 amount0Max, uint128 amount1Max)) returns (uint256, uint256)"],
};

const log = (...a) => console.log(new Date().toISOString().slice(0, 19), ...a);
const fmt = v => ethers.formatEther(v);
const why = e => (e.revert ? e.revert.name : e.shortMessage || e.reason || e.message || String(e)).slice(0, 140);
const isRevert = e => e.code === "CALL_EXCEPTION";

async function writeAddrs(file) {
  const run = JSON.parse(fs.readFileSync(file, "utf8"));
  const made = run.transactions.filter(t => t.transactionType === "CREATE");
  // forge leaves contractName null when a file has its own compiler profile (CargoMiner via-IR): fall back to the
  // fixed CREATE order of DeployCargo.deploy(); the on-chain sink check below catches any mismatch.
  const ORDER = made.length === 8 // Season 2 script: CargoDesign right after CargoMiner
    ? ["CargoToken", "CargoDock", "CargoMiner", "CargoDesign", "CargoBurner", "CargoPol", "CargoPol", "CargoReserve"]
    : ["CargoToken", "CargoDock", "CargoMiner", "CargoBurner", "CargoPol", "CargoPol", "CargoReserve"];
  // (forge may name some CREATEs and not others, so fill only the null ones, and only if the named ones sit in that order)
  if (made.length === ORDER.length && made.every((t, i) => !t.contractName || t.contractName === ORDER[i])) made.forEach((t, i) => (t.contractName = ORDER[i]));
  const by = n => made.filter(t => t.contractName === n).map(t => ethers.getAddress(t.contractAddress));
  const pols = by("CargoPol"); // deploy order: cargoPol (CARGO-OKB) then bemPol (BEM-OKB)
  const out = {
    token: by("CargoToken")[0], dock: by("CargoDock")[0], miner: by("CargoMiner")[0], burner: by("CargoBurner")[0],
    cargoPol: pols[0], bemPol: pols[1], reserve: by("CargoReserve")[0],
  };
  for (const [k, v] of Object.entries(out)) if (!v) throw new Error(`missing ${k} in ${file}`);
  const design = by("CargoDesign")[0];
  if (design) out.design = design; // Season 2: site + watcher read it
  // sanity check against the chain: the dock's sinks must be these contracts
  const p = provider(), dock = new ethers.Contract(out.dock, ABI.dock, p);
  const cp = new ethers.Contract(out.cargoPol, ABI.pol, p), b = new ethers.Contract(out.burner, ABI.burner, p);
  const ok = (await dock.cargoPol()) === out.cargoPol && (await dock.bemPol()) === out.bemPol &&
    (await dock.reserve()) === out.reserve && (await dock.burner()) === out.burner &&
    (await b.pool()) === (await cp.pool()) && (await cp.sqrtP0()) !== 0n;
  if (!ok) throw new Error("addresses do not match the dock's sinks on chain: wrong broadcast file or RPC");
  fs.mkdirSync(path.dirname(ADDRS), { recursive: true });
  fs.writeFileSync(ADDRS, JSON.stringify(out, null, 2) + "\n");
  log("wrote", ADDRS, out);
}

const provider = () => new ethers.JsonRpcProvider(RPC, 196, { staticNetwork: true, batchMaxCount: 1 }); // rpc.xlayer.tech drops batched replies

function load(runner) {
  const a = JSON.parse(fs.readFileSync(ADDRS, "utf8"));
  return {
    a,
    dock: new ethers.Contract(a.dock, ABI.dock, runner),
    miner: new ethers.Contract(a.miner, ABI.miner, runner),
    cargoPol: new ethers.Contract(a.cargoPol, ABI.pol, runner),
    bemPol: new ethers.Contract(a.bemPol, ABI.pol, runner),
    burner: new ethers.Contract(a.burner, ABI.burner, runner),
    reserve: new ethers.Contract(a.reserve, ABI.reserve, runner),
  };
}

async function seasons(p, C) {
  const n = Number(await C.dock.seasonCount());
  const out = [];
  for (let i = 0; i < n; i++) {
    const s = await C.dock.seasons(i);
    out.push({ i, price: s.price, owed: await new ethers.Contract(s.transistors, ABI.transistors, p).owed(C.a.dock) });
  }
  return out;
}

// WOKB / other-token fees a harvest() would collect now (npm.collect simulated as the POL contract).
async function pendingFees(p, pol, addr) {
  const npm = new ethers.Contract(await pol.npm(), ABI.npm, p);
  const wokbIs0 = (await pol.token0()) === (await pol.wokb());
  const ids = [await pol.tokenId()];
  for (let i = 0; ; i++) {
    try { ids.push(await pol.bidIds(i)); } catch (e) { if (isRevert(e)) break; throw e; }
  }
  let w = 0n, o = 0n;
  const MAX = (1n << 128n) - 1n;
  for (const id of ids) {
    if (id === 0n) continue;
    const [a0, a1] = await npm.collect.staticCall([id, addr, MAX, MAX], { from: addr });
    w += wokbIs0 ? a0 : a1; o += wokbIs0 ? a1 : a0;
  }
  return { w, o };
}

async function card(p, pol) {
  const s = await new ethers.Contract(await pol.pool(), ABI.pool, p).slot0();
  return { tick: s.tick, card: Number(s.card), next: Number(s.cardNext) };
}

// Simulate, then send. Returns true if sent (or would be sent in DRY). Never throws.
async function act(label, c, fn, args = []) {
  try { await c[fn].staticCall(...args); } catch (e) { log(`skip ${label}: ${why(e)}`); return { ok: false, e }; }
  if (DRY) { log(`DRY ok ${label}`); return { ok: true }; }
  try {
    const tx = await c[fn](...args);
    const r = await tx.wait(1, 120_000);
    log(`sent ${label} ${tx.hash} gas ${r.gasUsed}`);
    return { ok: true };
  } catch (e) { log(`FAIL ${label}: ${why(e)}`); return { ok: false, e }; }
}

async function status(p, C) {
  for (const s of await seasons(p, C)) log(`season ${s.i + 1}: price ${fmt(s.price)} OKB, owed to dock ${fmt(s.owed)} OKB`);
  log(`miner voyage fees (charter + bills) ${fmt(await C.miner.voyageFees())} OKB`);
  for (const k of ["cargoPol", "bemPol", "burner", "reserve"]) log(`${k} OKB balance ${fmt(await p.getBalance(C.a[k]))}`);
  for (const k of ["cargoPol", "bemPol"]) {
    const c = await card(p, C[k]), f = await pendingFees(p, C[k], C.a[k]);
    log(`${k} pool tick ${c.tick} cardinality ${c.card}/${c.next}, pending fees ${fmt(f.w)} WOKB + ${fmt(f.o)} other`);
  }
  log(`reserve share ${fmt(await C.reserve.floorPerCargo())} OKB/CARGO, free ${fmt(await C.reserve.freeOkb())} OKB`);
}

async function pass(p, C, me) {
  const gas = await p.getBalance(me);
  if (gas < MIN_GAS_OKB) { log(`STOP: keeper gas ${fmt(gas)} OKB < ${fmt(MIN_GAS_OKB)}; top up ${me}`); return; }
  if (DRY) log("DRY: each step is simulated on the state before this pass (later steps don't see earlier ones)");
  // 0. TWAP history: both pools need cardinality >= CARD (set at deploy; re-check)
  for (const k of ["cargoPol", "bemPol"]) if ((await card(p, C[k])).next < CARD) await act(`${k}.prepare(${CARD})`, C[k], "prepare", [CARD]);
  // 1. sweep mint OKB of every season into the split
  for (const s of await seasons(p, C)) if (s.owed >= MIN_OKB) await act(`sweep(${s.i}) ${fmt(s.owed)} OKB`, C.dock, "sweep", [s.i]);
  // 1b. voyage fees (charter + bill sales) -> 35 BEM POL / 35 team / 15 burner / 15 reserve; before add/burn below
  const vf = await C.miner.voyageFees();
  if (vf >= MIN_OKB) await act(`miner.sweepVoyageFees ${fmt(vf)} OKB`, C.miner, "sweepVoyageFees");
  // 2. harvest fees only when worth it (BEM fees go back in through bemPol.add, so harvest before add)
  for (const k of ["bemPol", "cargoPol"]) {
    const f = await pendingFees(p, C[k], C.a[k]);
    if (f.w >= MIN_FEE_OKB) await act(`${k}.harvest ${fmt(f.w)} WOKB`, C[k], "harvest");
  }
  // 3. BEM-OKB POL
  if ((await p.getBalance(C.a.bemPol)) >= MIN_OKB) await act("bemPol.add", C.bemPol, "add");
  // 4. CARGO-OKB POL: add() at the price once miners' CARGO is in the pool, else addBid() (OKB-only bid)
  if ((await p.getBalance(C.a.cargoPol)) >= MIN_OKB) {
    if (!(await act("cargoPol.add", C.cargoPol, "add")).ok) await act("cargoPol.addBid", C.cargoPol, "addBid");
  }
  // 5. buy & burn, max MAX_BURN_OKB per tx; halve only on slippage (size-independent reverts stop the step)
  const bal = await p.getBalance(C.a.burner);
  let amt = bal < MAX_BURN_OKB ? bal : MAX_BURN_OKB;
  while (amt >= MIN_OKB) {
    const r = await act(`burner.burn ${fmt(amt)} OKB`, C.burner, "burn", [amt]);
    if (r.ok || (r.e && r.e.revert)) break; // PriceMoved / Nothing: size does not matter
    amt /= 2n;
  }
  log(`pass done, keeper gas ${fmt(await p.getBalance(me))} OKB`);
}

async function main() {
  const cmd = process.argv[2] || "status";
  if (cmd === "addrs") return writeAddrs(process.argv[3]);
  const p = provider();
  if (cmd === "status") return status(p, load(p));
  if (cmd === "watch") return W.watch(p, load(p).a);
  if (cmd === "report") return W.report(p, load(p).a, true);
  let pk = process.env.KEEPER_PK;
  if (!pk) throw new Error("KEEPER_PK not set");
  if (!pk.startsWith("0x")) pk = "0x" + pk;
  const wallet = new ethers.Wallet(pk, p);
  const C = load(wallet);
  log(`keeper ${wallet.address}${DRY ? " (DRY)" : ""}`);
  if (cmd === "run") return pass(p, C, wallet.address);
  if (cmd === "loop") {
    if (!(INTERVAL_MIN >= 1)) throw new Error("INTERVAL_MIN must be >= 1");
    let errs = 0, wErrs = 0, rErrs = 0;
    for (;;) {
      try { await pass(p, C, wallet.address); errs = 0; } catch (e) {
        log("pass error:", why(e));
        if (++errs === 3) await W.send(`[Cargo keeper] 3 passes in a row failed. Last: ${why(e)}`);
      }
      // alerts + daily report never stop the keeper; 3 failures in a row are reported too (review M10)
      try { await W.watch(p, C.a, wallet.address); wErrs = 0; } catch (e) {
        log("watch error:", why(e));
        if (++wErrs === 3) await W.send(`[Cargo keeper] admin-event watch failed 3 times in a row. Last: ${why(e)}`);
      }
      try { await W.report(p, C.a); rErrs = 0; } catch (e) {
        log("report error:", why(e));
        if (++rErrs === 3) await W.send(`[Cargo keeper] daily report failed 3 times in a row. Last: ${why(e)}`);
      }
      await new Promise(r => setTimeout(r, INTERVAL_MIN * 60_000));
    }
  }
  throw new Error(`unknown command ${cmd}`);
}

main().catch(e => { console.error(why(e)); process.exit(1); });
