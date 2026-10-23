// B1 sim: does a berth-hopping bot beat passive users once move() has a fee + cooldown?
// Usage: node sim/berth-bot-sim.js   (prints bot edge vs passive, per fee/cooldown/price)
// Model: 25 berths, 0.5987 CARGO/berth/voyage split by power. Humans arrive (Poisson), 50% pick the quietest
// berth, 50% random, never move, leave after a random life. Bots (1 OKB power each = S1 wallet cap) move to the
// quietest berth when allowed by cooldown and the expected gain over the cooldown beats the fee.
const BASE = process.env.BASE || "still"; // still = never moves; human = same rule, checks 3x/day
const MODE = process.env.MODE || "okb";
const HORIZON = +(process.env.HORIZON || 72); // voyages a bot expects to profit from one move
const BERTHS = 25, R = 5000 * 25 / 29 / 25 / 288, DAYS = 14, V = DAYS * 288;

function rng(seed) { let s = seed >>> 0; return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 2 ** 32); }

function run({ feeBps, cooldown, price, bots, arrivalsPerDay, seed, check = 1 }) {
  const rnd = rng(seed);
  const pw = new Array(BERTHS).fill(0);
  let humans = [], hPV = 0, hCargo = 0;
  const B = Array.from({ length: bots }, () => ({ p: 1, berth: -1, next: 0, cargo: 0, fee: 0, pv: 0, moves: 0 }));
  for (let v = 0; v < V; v++) {
    // arrivals
    let n = 0, lam = arrivalsPerDay / 288, L = Math.exp(-lam), k = 1;
    do { k *= rnd(); n++; } while (k > L); n--;
    for (let i = 0; i < n; i++) {
      const p = 0.02 + rnd() * 0.98;
      const b = rnd() < 0.5 ? pw.indexOf(Math.min(...pw)) : Math.floor(rnd() * BERTHS);
      pw[b] += p; humans.push({ p, b, until: v + Math.floor(288 * (1 + rnd() * 13)) });
    }
    humans = humans.filter(h => (h.until > v) || ((pw[h.b] -= h.p), false));
    // bots
    for (const t of B) {
      if (t.berth < 0) { const b = pw.indexOf(Math.min(...pw)); t.berth = b; pw[b] += t.p; t.next = v + cooldown; continue; }
      if (v < t.next || v % check) continue;
      let best = -1, bestP = Infinity;
      for (let b = 0; b < BERTHS; b++) if (b !== t.berth && pw[b] < bestP) { bestP = pw[b]; best = b; }
      const cur = t.p / pw[t.berth], nw = t.p / (bestP + t.p);
      const fee = MODE === "cargo" ? feeBps * R * t.p / (bestP + t.p) * price : t.p * feeBps / 10000; // cargo mode: feeBps = K voyages of new-berth reward, burned
      const gain = (nw - cur) * R * Math.max(cooldown, HORIZON) * price;
      if (gain > fee) { pw[t.berth] -= t.p; pw[best] += t.p; t.berth = best; t.fee += fee; t.moves++; t.next = v + cooldown; }
    }
    // rewards
    for (const h of humans) { hCargo += R * h.p / pw[h.b]; hPV += h.p; }
    for (const t of B) { t.cargo += R * t.p / pw[t.berth]; t.pv += t.p; }
  }
  const hRate = hCargo * price / hPV;
  const bCargo = B.reduce((a, t) => a + t.cargo, 0), bFee = B.reduce((a, t) => a + t.fee, 0), bPV = B.reduce((a, t) => a + t.pv, 0);
  const bRate = (bCargo * price - bFee) / bPV;
  return { edge: bRate / hRate - 1, moves: B.reduce((a, t) => a + t.moves, 0) / bots / DAYS };
}

const prices = [0.00005, 0.001, 0.01];
const configs = MODE === "cargo" ? [[0, 12], [12, 12], [24, 12], [12, 24], [0, 24]] : [[0, 1], [100, 1], [0, 12], [50, 12], [100, 12], [100, 24], [200, 12]];
for (const arrivalsPerDay of [20, 100]) for (const bots of [3, 10]) {
  console.log(`\narrivals ${arrivalsPerDay}/day, bots ${bots}  (edge = mover net OKB per power / baseline " + BASE + ", avg 5 seeds; moves/bot/day)`);
  for (const [feeBps, cooldown] of configs) {
    const row = prices.map(price => {
      let e = 0, m = 0;
      for (let s = 1; s <= 5; s++) { const a = { bots, arrivalsPerDay, price, seed: s * 7919 }; const r = run({ ...a, feeBps, cooldown }), z = BASE === "human" ? run({ ...a, feeBps, cooldown, check: 96 }) : run({ ...a, feeBps: 1e9, cooldown }); e += (1 + r.edge) / (1 + z.edge) - 1; m += r.moves; }
      return `P=${price}: ${(e / 5 * 100).toFixed(1).padStart(6)}% ${(m / 5).toFixed(1).padStart(5)}mv`;
    });
    console.log(`fee ${String(feeBps).padStart(3)}bps cd ${String(cooldown).padStart(2)}v | ${row.join(' | ')}`);
  }
}
