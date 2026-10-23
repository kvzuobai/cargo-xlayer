// Cargo season sim (step 3): stepped season price + BEM step, reserve share vs CARGO-OKB pool, arb to the reserve.
// Usage: node sim/cargo-sim.js [days]          Override: $env:OVER='{"sellShare":0.8}'
// Old FabX-vs-Cargo model: tools/cargo-sim-v0.js. Pool math: same v3 model as tools/p0-sim.js.
// Follows the contracts (s36):
//   CargoDock.sweep: mint OKB 10% team / reserveShare reserve / BEM 35% +5 pts per season (cap 50) / CARGO POL the rest.
//   Stake: dock fee 5% of rig value -> 45% burner / 45% BEM / 10% team. Season >= 2: 20% of rig value bought & burned.
//   Power = transistors x season price = OKB paid, so the price step does NOT change power per OKB; early = less power
//   competing for the same 5,000 CARGO/day.
//   CargoReserve: share = free OKB / (totalSupply + unclaimed); redeem burns now, pays share x 99% after 24h.
//   CargoPol: bootstrap at deploy (0.01 OKB seed, OKB-only bid P0 -> P0/10), then add() / addBid() as in p0-sim.
// R = total season-1 mint OKB (S1 cap 2M x 0.002 = 4,000 OKB). Season n total = R x s2Ratio^(n-1).
// Demand inside a season fades exp(-d/tau). Every behaviour number is an ASSUMPTION, not a forecast.

const DAYS = +process.argv[2] || 90;
const BASE = {
  P0: 0.00005, reserveShare: 0.10, seed: 0.01,
  emission: 5000, price1: 0.002, step: 1.25, seasonDays: 30,
  bem0: 0.35, bemStep: 0.05, bemMax: 0.50,
  s2Ratio: 0.6, tau: 10,
  sellShare: 0.6,   // share of held CARGO miners try to sell each day
  buyShare: 0.2,    // organic CARGO buys (OKB) as share of the day's mint OKB
  dayCap: 1.1,      // buyers / burner accept at most +10% price per day (TWAP-bounded)
  panic: false,     // true: miners dump with no daily limit and post no asks (still redeem when the pool pays less)
  fee: 0.01, redeemFee: 0.01, weekCohort: 7,
  // Voyage hybrid (s39): 25 berths, voyage 5 min (288/day). Cargo CPU stays the money engine (mint split above).
  offRatio: 0,      // official TapeOut circuits loaded, OKB value at ref price, as a share of Cargo mint OKB (same demand curve)
  expressPay: 0,    // CARGO burned for Express, as a share of the extra Express emission (4/29 of daily; max rational = 1)
  charters: 0,      // berths chartered full-time by outside projects
  charterFee: 0.0005, // OKB per berth per voyage
  lading: 0,        // share of loaded value traded as bills of lading per day (1% fee)
};
const VOY = 288, FEE_SPLIT = { bem: 0.35, team: 0.35, burn: 0.15, reserve: 0.15 }; // voyage OKB fees (charter, lading)
const OVER = process.env.OVER ? JSON.parse(process.env.OVER) : {};

function run(R, over = {}) {
  const P = { ...BASE, ...OVER, ...over };
  const pos = [];
  let s = Math.sqrt(P.P0);
  const FR = [Math.sqrt(1e-15), Math.sqrt(1e3)];
  let polOkb = 0, burnerOkb = 0, reserve = 0, reserveIn = 0, reservePaid = 0, team = 0, bem = 0, y30 = 0;
  let supply = 0, burned = 0, minerHeld = 0, power = 0, mintTotal = 0, lastBid = 0; // bootstrap sets lastNewBid
  let minerSold = 0, minerRedeemed = 0, arbRedeemed = 0; // OKB miners got from pool / from reserve; CARGO arb redeemed
  // week-1 cohort: share of emission received; realized OKB attributed pro-rata to CARGO received
  let coPower = 0, coMint = 0, coCargo = 0, cargoOut = 0;
  let crossDay = null, minS = s, maxS = s;
  let offTotal = 0, voyFees = 0, expressBurn = 0;
  const snap = {};
  const share = () => (supply > 0 ? reserve / supply : Infinity);

  const activeDown = () => pos.filter(p => p.sa < s && p.sb >= s).reduce((a, p) => a + p.L, 0);
  const activeUp = () => pos.filter(p => p.sa <= s && p.sb > s).reduce((a, p) => a + p.L, 0);
  const sell = (x, lo = 0) => { // CARGO x -> OKB, price not below sqrt `lo`; unsold CARGO in sell.left
    let out = 0; x *= 1 - P.fee;
    for (let k = 0; k < 60 && x > 1e-12 && s > lo; k++) {
      const L = activeDown();
      const below = pos.flatMap(p => [p.sa, p.sb]).filter(b => b < s - 1e-18);
      if (!below.length) break;
      const nb = Math.max(lo, ...below);
      if (L === 0) { s = nb; continue; }
      const dx = L * (1 / nb - 1 / s);
      if (x <= dx) { const s2 = 1 / (1 / s + x / L); out += L * (s - s2); s = s2; x = 0; }
      else { out += L * (s - nb); x -= dx; s = nb; }
    }
    minS = Math.min(minS, s); sell.left = x / (1 - P.fee);
    return out;
  };
  const buy = (y, lim) => { // OKB y -> CARGO, price not above sqrt `lim`; returns [cargo, okbSpent]
    let out = 0, left = y * (1 - P.fee); const s0 = s;
    for (let k = 0; k < 60 && left > 1e-12 && s < lim; k++) {
      const L = activeUp();
      const above = pos.flatMap(p => [p.sa, p.sb]).filter(b => b > s + 1e-18);
      const nb = Math.min(lim, ...above);
      if (L === 0) { if (!above.length) break; s = nb; continue; }
      const dy = L * (nb - s);
      if (left <= dy) { const s2 = s + left / L; out += L * (1 / s - 1 / s2); s = s2; left = 0; }
      else { out += L * (1 / s - 1 / nb); left -= dy; s = nb; }
    }
    if (out === 0) s = s0; // nothing bought: nobody pays to push the price across an empty gap
    maxS = Math.max(maxS, s);
    return [out, y - left / (1 - P.fee)];
  };
  const poolOkb = () => pos.reduce((a, p) => a + (s > p.sa ? p.L * (Math.min(s, p.sb) - p.sa) : 0), 0);
  const burnCargo = c => { supply -= c; burned += c; };
  const redeem = c => { // CargoReserve.redeem: pro-rata, 1% stays in reserve
    if (c <= 0 || supply <= 0) return 0;
    const okb = reserve * c / supply * (1 - P.redeemFee);
    reserve -= okb; reservePaid += okb; burnCargo(c);
    return okb;
  };
  const okbFlow = (okb, cargo) => { const f = okb * P.fee; burnerOkb += 0.7 * f; y30 += 0.3 * f; burnCargo(cargo * P.fee); };

  // deploy: bootstrap() with the seed -> OKB-only bid P0 -> P0/10
  let bid = { sa: Math.sqrt(P.P0 / 10), sb: Math.sqrt(P.P0), L: P.seed / (Math.sqrt(P.P0) - Math.sqrt(P.P0 / 10)) };
  pos.push(bid);
  const W = Array.from({ length: P.seasonDays }, (_, d) => Math.exp(-d / P.tau));
  const WS = W.reduce((a, b) => a + b, 0);

  for (let t = 0; t < DAYS; t++) {
    const season = Math.floor(t / P.seasonDays), d = t % P.seasonDays;
    const mint = R * Math.pow(P.s2Ratio, season) * W[d] / WS;
    const bemShare = Math.min(P.bemMax, P.bem0 + season * P.bemStep);
    mintTotal += mint; power += mint;
    if (t < P.weekCohort) { coPower += mint; coMint += mint * 1.05; }
    team += 0.10 * mint + 0.05 * mint * 0.10;
    reserve += P.reserveShare * mint; reserveIn += P.reserveShare * mint;
    bem += bemShare * mint + 0.05 * mint * 0.45;
    polOkb += (1 - 0.10 - P.reserveShare - bemShare) * mint;
    burnerOkb += 0.05 * mint * 0.45;
    // voyage: official circuits pay only the 5% loading (dock) fee, same split; they add power (dilute)
    const off = P.offRatio * R * Math.pow(P.s2Ratio, season) * W[d] / WS;
    power += off; offTotal += off;
    team += 0.05 * off * 0.10; bem += 0.05 * off * 0.45; burnerOkb += 0.05 * off * 0.45;
    const vf = P.charters * VOY * P.charterFee + P.lading * power * 0.01;
    voyFees += vf; team += FEE_SPLIT.team * vf; bem += FEE_SPLIT.bem * vf; burnerOkb += FEE_SPLIT.burn * vf;
    reserve += FEE_SPLIT.reserve * vf; reserveIn += FEE_SPLIT.reserve * vf;

    // emission
    supply += P.emission; minerHeld += P.emission; cargoOut += P.emission;
    coCargo += P.emission * (power > 0 ? coPower / power : 0);
    const ex = Math.min(minerHeld, P.expressPay * P.emission * 4 / 29); // Express seats paid in CARGO, burned
    minerHeld -= ex; burnCargo(ex); expressBurn += ex;

    // miners: sell down to the redeem value (panic: no daily limit), redeem the rest of today's sell order;
    // disciplined miners rest what they keep as asks from max(price, redeem value) up to x3 (removed at day end)
    const want = t === 0 ? 0 : minerHeld * P.sellShare; minerHeld -= want; // day 0: rigs still being staked
    const rv = share() * (1 - P.redeemFee);
    const lo = P.panic ? Math.sqrt(rv) : Math.max(s / Math.sqrt(P.dayCap), Math.sqrt(rv)); // nobody sells below redeem
    const got = sell(want, lo); minerSold += got; burnCargo((want - sell.left) * P.fee); // sell fee is CARGO, burned by harvest
    let left = sell.left;
    if (left > 0 && s * s <= rv * 1.0001) { minerRedeemed += redeem(left); left = 0; }
    minerHeld += left;
    let ask = null;
    if (!P.panic && minerHeld > 0) {
      const sa = Math.max(s, Math.sqrt(rv)), sb = sa * Math.sqrt(3);
      ask = { sa, sb, L: minerHeld / (1 / sa - 1 / sb) }; pos.push(ask); minerHeld = 0;
    }

    // keeper: add() (full range, needs CARGO within 3%) else addBid()
    if (polOkb > 0) {
      const half = polOkb / 2, saved = pos.map(p => ({ ...p })), s0 = s, bidKey = [bid.sa, bid.sb], ai = pos.indexOf(ask);
      const [c, spent] = buy(half, s * Math.sqrt(1.03));
      if (spent >= half * 0.999) {
        pos.push({ sa: FR[0], sb: FR[1], L: Math.min(c / (1 / s - 1 / FR[1]), half / (s - FR[0])) }); polOkb = 0;
      } else {
        pos.length = 0; saved.forEach(p => pos.push(p)); s = s0;
        bid = pos.find(p => p.sa === bidKey[0] && p.sb === bidKey[1]); if (ask) ask = pos[ai];
        if (s >= bid.sb) { bid.L += polOkb / (bid.sb - bid.sa); polOkb = 0; }
        else if (t - lastBid >= 7) {
          bid = { sa: s / Math.sqrt(10), sb: s, L: polOkb / (s - s / Math.sqrt(10)) };
          pos.push(bid); polOkb = 0; lastBid = t;
        }
      }
    }

    // buyers: organic, S2+ stake burn (20% of rig value), burner
    const lim = s * Math.sqrt(P.dayCap);
    const [, a] = buy(P.buyShare * mint, lim); okbFlow(a, 0);
    if (season >= 1) { const [c2, sp] = buy(0.2 * mint, lim); burnCargo(c2); okbFlow(sp, 0); }
    const [c3, sp3] = buy(burnerOkb, lim); burnCargo(c3); burnerOkb -= sp3; okbFlow(sp3, 0);

    // arb: pool below redeem value -> buy CARGO (no cap) up to it, redeem
    const rv2 = share() * (1 - P.redeemFee) * (1 - P.fee);
    if (s * s < rv2) {
      const [c4, sp4] = buy(1e9, Math.sqrt(rv2)); okbFlow(sp4, 0);
      arbRedeemed += c4; redeem(c4);
    }
    if (ask) { // what miners sold through their asks
      minerSold += s > ask.sa ? ask.L * (Math.min(s, ask.sb) - ask.sa) : 0;
      minerHeld += s < ask.sb ? ask.L * (1 / Math.max(s, ask.sa) - 1 / ask.sb) : 0;
      pos.splice(pos.indexOf(ask), 1);
    }
    if (crossDay === null && share() < P.P0) crossDay = t;
    if ([0, 6, 29, 30, 44, 59, 89].includes(t)) snap[t] = { pool: s * s, share: share(), paid: reservePaid / Math.max(reserveIn, 1e-12) };
  }
  const realized = minerSold + minerRedeemed;
  const coShare = cargoOut > 0 ? coCargo / cargoOut : 0;
  return {
    R, P, snap, crossDay, pool: s * s, share: share(), min: minS * minS, max: maxS * maxS,
    reserve, reserveIn, reservePaid, team, bem, y30, mintTotal, burned, supply, poolOkb: poolOkb(),
    minerSold, minerRedeemed, arbRedeemed, offTotal, voyFees, expressBurn,
    coRebate: coMint > 0 ? coShare * realized / coMint : 0,          // week-1 miners: OKB back / OKB paid (incl. 5% dock fee)
    coFromReserve: coMint > 0 ? coShare * minerRedeemed / coMint : 0,
    coHeldValue: coMint > 0 ? coShare * minerHeld * Math.max(s * s, share()) / coMint : 0,
  };
}

module.exports = { run, BASE };
if (require.main !== module) return;

const f = (x, d = 2) => (x == null ? "  —" : Math.abs(x) >= 100 ? x.toFixed(0) : x.toFixed(d));
const e = x => x.toExponential(1);
const pct = x => (100 * x).toFixed(0) + "%";
const RS = [5, 50, 500, 4000];
const MODELS = { disciplined: { panic: false }, panic: { panic: true } };

console.log(`Cargo season sim, ${DAYS} days. P0 ${BASE.P0}, reserve ${pct(BASE.reserveShare)}, S2 = ${BASE.s2Ratio} x S1. Prices in OKB/CARGO.`);
for (const [m, mo] of Object.entries(MODELS)) {
  console.log(`\n[${m}] R=S1 mint OKB | share d1 / pool d1 | d7 share/pool | d30 share/pool | d60 share/pool | d90 share/pool | share<P0 day | reserve paid d7/d30/end | week-1 miners back (from reserve) + still hold`);
  for (const R of RS) {
    const r = run(R, mo), S = r.snap, sp = k => S[k] ? `${e(S[k].share)}/${e(S[k].pool)}` : "—";
    console.log(`${String(R).padStart(5)} | ${sp(0)} | ${sp(6)} | ${sp(29)} | ${sp(59)} | ${sp(89)} | ${f(r.crossDay, 0).padStart(4)} | ` +
      `${pct(S[6].paid)} / ${pct(S[29].paid)} / ${pct(r.reservePaid / r.reserveIn)} | ${pct(r.coRebate)} (${pct(r.coFromReserve)}) + ${pct(r.coHeldValue)}`);
  }
}

console.log(`\nS2 effect (disciplined): S2 on vs no S2 (s2Ratio 0). pool / share at d45 and d60, team, BEM OKB`);
for (const R of RS) {
  const a = run(R, { s2Ratio: BASE.s2Ratio }), b = run(R, { s2Ratio: 0 });
  console.log(`${String(R).padStart(5)} | with S2 pool ${e(a.snap[44].pool)} share ${e(a.snap[44].share)} -> d60 ${e(a.snap[59].pool)} | no S2 pool ${e(b.snap[44].pool)} share ${e(b.snap[44].share)} -> d60 ${e(b.snap[59].pool)} | team ${f(a.team)} vs ${f(b.team)} | BEM ${f(a.bem)} vs ${f(b.bem)}`);
}

console.log(`
Voyage hybrid (disciplined, ${DAYS}d). OKB: team / to BEM-OKB POL / voyage fees | CARGO burned (Express) | end pool price | week-1 back + hold`);
const HY = {
  "season only (old)": {},
  "hybrid, no charter": { offRatio: 0.5, expressPay: 0.5, lading: 0.05 },
  "hybrid + 2 charters": { offRatio: 0.5, expressPay: 0.5, lading: 0.05, charters: 2 },
  "hybrid + 10 charters": { offRatio: 0.5, expressPay: 0.5, lading: 0.05, charters: 10 },
};
for (const R of RS) for (const [k, o] of Object.entries(HY)) {
  const r = run(R, o);
  console.log(`${String(R).padStart(5)} ${k.padEnd(21)} | team ${f(r.team).padStart(6)} | BEM ${f(r.bem).padStart(6)} | fees ${f(r.voyFees).padStart(5)} | burned ${e(r.burned)} (express ${e(r.expressBurn)}) | pool ${e(r.pool)} | ${pct(r.coRebate)} + ${pct(r.coHeldValue)}`);
}

// Decision grid. Rule (fixed before reading): reserve share must (a) never be drained > 50% by d30 in panic at R=50,
// (b) keep share >= P0 until d30 at R >= 50. Among options passing, pick the one with the highest panic d90 pool price
// at R=50. P0: highest P0 whose panic d90 pool >= 0.8 x P0 at R=5 and R=50 (same SAFE rule as hype-sim).
console.log(`\nDecision grid (R=5 / 50 / 500, panic): d90 pool/P0 | min pool/P0 | share<P0 day | reserve paid d30 | CARGO pool OKB d90 | team`);
for (const rsv of [0.05, 0.10, 0.15]) for (const p0 of [0.00002, 0.00005, 0.0001, 0.0002]) {
  const cells = [5, 50, 500].map(R => {
    const r = run(R, { panic: true, reserveShare: rsv, P0: p0 });
    return `${f(r.pool / p0).padStart(5)} ${f(r.min / p0).padStart(4)} ${f(r.crossDay, 0).padStart(3)} ${pct(r.snap[29].paid).padStart(4)} ${f(r.poolOkb, 1).padStart(6)} ${f(r.team, 1).padStart(6)}`;
  });
  console.log(`rsv ${pct(rsv).padStart(3)} P0 ${p0.toFixed(5)} | ${cells.join(" | ")}`);
}
