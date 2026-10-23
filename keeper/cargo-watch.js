// Cargo watch: admin-event alerts (N3) + daily on-chain report (N4), sent to Telegram. Used by cargo-keeper.js loop.
// Env: TG_TOKEN, TG_CHAT (unset = log only), STATE (default ops/keeper-state.json), REPORT_HOUR (UTC, default 0),
//      WARN_GAS_OKB (default 0.02). Read-only: never sends a transaction. Review 2026-10-24 (M7–M13, L6) applied.
const fs = require("fs");
const path = require("path");
const { ethers } = require("ethers");

const STATE = process.env.STATE || path.join(__dirname, "..", "ops", "keeper-state.json");
const REPORT_HOUR = +(process.env.REPORT_HOUR || 0);
const WARN_GAS = ethers.parseEther(process.env.WARN_GAS_OKB || "0.02");
const CHUNK = 100; // blocks per getLogs call (rpc.xlayer.tech rejects wider ranges)
const MAX_CHUNKS = 100; // per watch() call, so a long outage never stalls the keeper pass (backfill continues next pass)
const CONFIRM = 5; // stay behind head: a load-balanced RPC node may lag
const RESUME_BACK = 2000; // blocks to re-scan when the state file is lost or corrupt
const SITE = "https://1-2-387.tapekit.org/";

const EV = {
  miner: [
    "event WiringQueued(address oracle, address bemPol, address burner, address reserve, address team, uint256 readyAt)",
    "event SinksSet(address bemPol, address burner, address reserve, address team)",
    "event OracleSet(address oracle)",
    "event OfficialQueued(address indexed cpu, uint256 refPrice, uint256 readyAt)",
    "event OfficialSet(address indexed cpu, bool active)",
  ],
  dock: [
    "event OwnerChanged(address owner)",
    "event SeasonOpened(uint256 indexed season, address cpu, address transistors, uint256 price, uint256 cap)",
    "event SinksSet(address cargoPol, address bemPol, address reserve, address burner)",
  ],
  design: [ // Season 2
    "event JobQueued(uint256 indexed job, string name, address refCpu, uint256 refId, uint256 k, uint256 readyAt)",
    "event JobRetired(uint256 indexed job)",
    "event OwnerChanged(address owner)",
  ],
};
const RD = {
  dock: [
    "function pendingOwner() view returns (address)", "function seasonCount() view returns (uint256)",
    "function seasons(uint256) view returns (address cpu, address transistors, uint128 price, uint64 cap, uint64 start)",
    "function totalMintOkb() view returns (uint256)", "function totalDockFeeOkb() view returns (uint256)",
  ],
  miner: [
    "function rigCount() view returns (uint256)", "function totalPower() view returns (uint256)", "function charteredNow() view returns (uint256)",
    "function pendingWiring() view returns (address, address, address, address, address, uint64 readyAt)",
    "function berths(uint256) view returns (uint128 power, uint64 last, uint256 acc)",
    "function rigs(uint256) view returns (address owner, address cpu, uint64 voyageMoved, uint8 berth, uint32 season, uint32 cIdx, uint256 id, uint256 power, uint256 cargoDebt, uint256 okbDebt, uint256 xDebt, uint256 price)",
  ],
  design: ["function pendingOwner() view returns (address)"],
  token: ["function totalSupply() view returns (uint256)", "function totalBurned() view returns (uint256)"],
  tr: ["function minted() view returns (uint256)"],
  pol: ["function totalOkbIn() view returns (uint256)"],
  reserve: ["function floorPerCargo() view returns (uint256)", "function freeOkb() view returns (uint256)"],
};

const log = (...a) => console.log(new Date().toISOString().slice(0, 19), ...a);
const okb = (v, d = 4) => Number(ethers.formatEther(v)).toFixed(d);
const int = v => Number(ethers.formatEther(v)).toLocaleString("en-US", { maximumFractionDigits: 0 });
const utc = s => new Date(Number(s) * 1000).toISOString().slice(0, 16) + "Z";
// n calls with at most `conc` in flight (the public RPC resets bursts of parallel requests)
async function each(n, fn, conc = 5) {
  const out = new Array(n);
  for (let i = 0; i < n; i += conc) {
    const part = await Promise.all([...Array(Math.min(conc, n - i))].map((_, j) => fn(i + j)));
    part.forEach((v, j) => (out[i + j] = v));
  }
  return out;
}

// State: atomic write (tmp + rename). A corrupt file is kept as .bad-<time> and flagged, never silently reset (M7).
function readState() {
  let raw;
  try { raw = fs.readFileSync(STATE, "utf8") } catch (e) { return {} } // first run
  try { return JSON.parse(raw) } catch (e) {
    const bad = `${STATE}.bad-${Date.now()}`;
    try { fs.renameSync(STATE, bad) } catch (e2) {}
    return { corrupt: bad };
  }
}
function writeState(s) {
  fs.mkdirSync(path.dirname(STATE), { recursive: true });
  const tmp = STATE + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(s, null, 2) + "\n");
  fs.renameSync(tmp, STATE);
}

// Returns true when delivered (or when Telegram is not configured: log only). Never throws (M9).
async function send(text) {
  log("notify:", text.replace(/\n/g, " | "));
  const { TG_TOKEN, TG_CHAT } = process.env;
  if (!TG_TOKEN || !TG_CHAT) return true;
  try {
    const r = await fetch(`https://api.telegram.org/bot${TG_TOKEN}/sendMessage`, {
      method: "POST", headers: { "content-type": "application/json" }, signal: AbortSignal.timeout(10_000),
      body: JSON.stringify({ chat_id: TG_CHAT, text, disable_web_page_preview: true }),
    });
    if (r.ok) return true;
    log("telegram error", r.status, (await r.text()).slice(0, 200));
  } catch (e) { log("telegram error", e.message) }
  return false;
}

function alertText(k, ev, l) {
  const args = ev.fragment.inputs.map((x, i) => `${x.name}=${x.name === "readyAt" ? utc(ev.args[i]) : ev.args[i]}`).join(", ");
  return `[Cargo ALERT] ${k}.${ev.name}\n${args}\nblock ${l.blockNumber} tx ${l.transactionHash}\nCheck: ${SITE}#dock (Admin powers)`;
}

// N3: admin events since the last checked block, plus state checks that cannot miss an event (M11).
async function watch(p, a, keeper) {
  let st = readState();
  const head = (await p.getBlockNumber()) - CONFIRM;
  if (st.corrupt) {
    const from = head - RESUME_BACK, bad = st.corrupt;
    st = { block: from };
    writeState(st);
    await send(`[Cargo keeper] state file was corrupt (kept as ${path.basename(bad)}). Re-scanning admin events from block ${from}.`);
  }
  if (!st.block) { st.block = head; writeState(st); log("watch: start at block", head); }
  const names = { [a.miner.toLowerCase()]: "miner", [a.dock.toLowerCase()]: "dock" };
  if (a.design) names[a.design.toLowerCase()] = "design";
  const ifc = Object.fromEntries(Object.values(names).map(k => [k, new ethers.Interface(EV[k])]));
  const addrs = Object.keys(names);
  for (let n = 0, from = st.block + 1; from <= head && n < MAX_CHUNKS; n++, from += CHUNK) {
    const to = Math.min(head, from + CHUNK - 1);
    const logs = await p.getLogs({ address: addrs, fromBlock: from, toBlock: to }); // one call for all contracts (M12)
    for (const l of logs) {
      const k = names[l.address.toLowerCase()];
      let ev; try { ev = ifc[k].parseLog(l) } catch (e) { continue }
      if (!ev) continue;
      if (!(await send(alertText(k, ev, l)))) return; // not delivered: keep the block, retry next pass (M9)
    }
    st.block = to; writeState(st);
  }
  const dock = new ethers.Contract(a.dock, RD.dock, p), miner = new ethers.Contract(a.miner, RD.miner, p);
  const checks = [
    ["pendingOwner", "dock.setOwner: pending owner is now", () => dock.pendingOwner(), ethers.ZeroAddress],
    ["wiringReadyAt", "miner.queueWiring: fee routes / oracle change queued, live at", async () => (await miner.pendingWiring()).readyAt.toString(), "0"],
  ];
  if (a.design) {
    const design = new ethers.Contract(a.design, RD.design, p);
    checks.push(["designPendingOwner", "design.setOwner: pending owner is now", () => design.pendingOwner(), ethers.ZeroAddress]);
  }
  for (const [key, msg, read, none] of checks) {
    const v = await read();
    if (v === (st[key] ?? none)) continue;
    if (v !== none && !(await send(`[Cargo ALERT] ${msg} ${key === "wiringReadyAt" ? utc(v) : v}\nCheck: ${SITE}#dock`))) continue;
    st[key] = v; writeState(st);
  }
  if (keeper) {
    const g = await p.getBalance(keeper), low = g < WARN_GAS;
    if (low !== !!st.gasWarned && (!low || await send(`[Cargo keeper] gas low: ${okb(g)} OKB on ${keeper}. Top up.`))) {
      st.gasWarned = low; writeState(st);
    }
  }
}

async function snapshot(p, a) {
  const C = k => new ethers.Contract(a[k], RD[k] || RD.pol, p);
  const dock = C("dock"), miner = C("miner"), token = C("token"), reserve = C("reserve");
  const n = Number(await dock.seasonCount());
  let nand = 0n;
  for (let i = 0; i < n; i++) nand += await new ethers.Contract((await dock.seasons(i)).transistors, RD.tr, p).minted();
  const rc = Number(await miner.rigCount()), owners = new Set();
  for (const r of await each(rc, i => miner.rigs(i))) if (r.owner !== ethers.ZeroAddress) owners.add(r.owner); // all rigs (M13)
  const bs = await each(25, i => miner.berths(i));
  const filled = bs.filter(b => b.power > 0n).length;
  const calls = [() => token.totalSupply(), () => token.totalBurned(), () => miner.totalPower(), () => miner.charteredNow(),
    () => dock.totalMintOkb(), () => dock.totalDockFeeOkb(), () => new ethers.Contract(a.bemPol, RD.pol, p).totalOkbIn(),
    () => reserve.floorPerCargo(), () => reserve.freeOkb()];
  const [supply, burned, power, chartered, mintOkb, feeOkb, bemIn, share, free] = await each(calls.length, i => calls[i]());
  return { dock: a.dock, nand: nand.toString(), wallets: owners.size, filled, supply: supply.toString(), burned: burned.toString(),
    power: power.toString(), chartered: Number(chartered), mintOkb: mintOkb.toString(), feeOkb: feeOkb.toString(),
    bemIn: bemIn.toString(), share: share.toString(), free: free.toString() };
}

function reportText(s, prev, day) {
  // a diff only when yesterday's field exists and comes from the same contracts (M8)
  const has = k => prev && prev.dock === s.dock && prev[k] !== undefined;
  const d = (k, f) => has(k) ? ` (${BigInt(s[k]) >= BigInt(prev[k]) ? "+" : "-"}${f(BigInt(s[k]) >= BigInt(prev[k]) ? BigInt(s[k]) - BigInt(prev[k]) : BigInt(prev[k]) - BigInt(s[k]))})` : "";
  const dn = k => has(k) ? ` (${s[k] - prev[k] >= 0 ? "+" : ""}${s[k] - prev[k]})` : "";
  return [`Cargo daily report ${day} (UTC, read from contracts)`,
    `NAND minted: ${BigInt(s.nand).toLocaleString("en-US")}${d("nand", x => x.toLocaleString("en-US"))}`,
    `Wallets with circuits on board: ${s.wallets}${dn("wallets")}`,
    `Berths with cargo: ${s.filled}/25 · power on board ${okb(s.power)} OKB`,
    `CARGO supply: ${int(s.supply)}${d("supply", int)} · burned ${int(s.burned)}${d("burned", int)}`,
    `Mint OKB total: ${okb(s.mintOkb)} · dock fees ${okb(s.feeOkb)}`,
    `OKB into BEM-OKB liquidity: ${okb(s.bemIn)}${d("bemIn", x => okb(x))}`,
    `Reserve: ${okb(s.free)} OKB free · share ${okb(s.share, 8)} OKB/CARGO`,
    `Berths chartered: ${s.chartered}`,
    `Verify: ${SITE}#dock`].join("\n");
}

// N4: one report per UTC day after REPORT_HOUR. force=true sends now (CLI). Marked done only when delivered.
async function report(p, a, force = false) {
  const st = readState(), now = new Date(), day = now.toISOString().slice(0, 10);
  if (st.corrupt) return; // watch() handles recovery first
  if (!force && (st.reportDay === day || now.getUTCHours() < REPORT_HOUR)) return;
  const s = await snapshot(p, a);
  if (!(await send(reportText(s, st.snap, day)))) return;
  Object.assign(st, { reportDay: day, snap: s }); writeState(st);
}

module.exports = { watch, report, send };
