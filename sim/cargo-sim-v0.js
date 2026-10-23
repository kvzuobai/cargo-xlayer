// Cargo mechanism simulation: FabX-style (mint OKB -> team) vs Cargo (mint OKB -> protocol-owned liquidity + buyback).
// Daily steps, 60 days. Usage: node tools/cargo-sim-v0.js [days]
// All demand numbers are ASSUMPTIONS calibrated loosely on FabX (Oct 2026): rig payback ~250d, spend fades 70-90% within a week.

const DAYS = +process.argv[2] || 60;
const OKB_USD = 114.57;

const BASE = {
  emission0: 10000,      // CARGO/day
  genesisCargo: 200000,  // 0.95% of 21M, minted once, locked as POL
  sellShare: 0.6,        // share of daily emission miners dump
  mintPrice0: 0.002,     // OKB per transistor
  curveM: 2_000_000,     // transistors minted before price doubles
  // demand: new mint OKB/day = D0 * exp(-t/tau) * clamp(roi/roiRef)
  D0: 300, tau: 7, roiRef: 365 / 250,
  turnover: 0.8,         // pool daily volume / pool TVL (BEM pool ~2.3, BEM/FAB ~0.2)
  poolFee: 0.01,
  // Cargo split of mint OKB
  team: 0.10, toCargoPol: 0.60, toBemVault: 0.30,
  bemVaultApr: 1.5,      // fee APR on the BEM/OKB slice (observed far higher; haircut for IL)
  maxVolUsd: 200000,     // CARGO pool volume cap/day (largest BEM pool on X Layer does ~$125-500k)
  bemPoolFeesUsd: 2000,  // all fees paid by BEM/WOKB pool per day, shared with existing LPs
  bemPoolTvlUsd: 85000,  // existing LP capital in that pool
  bemFeeSplit: { cargoBurn: 0.5, bemBuy: 0.4, team: 0.1 },
  cargoFeeSplit: { burn: 0.9, team: 0.1 },
};

// Optional overrides: $env:OVER='{"emission0":5000}'
const ENV_OVER = process.env.OVER ? JSON.parse(process.env.OVER) : {};

function run(design, over = {}) {
  const P = { ...BASE, ...ENV_OVER, ...over };
  // CARGO/OKB constant-product pool (full-range POL approximation)
  let pc = P.genesisCargo, po = 0; // reserves
  let power = 0, minted = 0, supply = P.genesisCargo, burned = 0;
  let reserve = 0, yieldPrev = 0, yieldTotal = 0, floorPx = 0;
  let teamOkb = 0, bemVault = 0, bemBoughtOkb = 0, mintTotal = 0, locked = 0, lockedOkbValue = 0, roundDeployed = 0, roundFees = 0;
  const rows = [];
  const price = () => (pc > 0 && po > 0 ? po / pc : 0);
  const sellCargo = c => { const out = po * c / (pc + c); pc += c; po -= out; return out; };
  const buyCargo = o => { const out = pc * o / (po + o); po += o; pc -= out; return out; };

  for (let t = 0; t < DAYS; t++) {
    const emission = P.emission0;
    const S = P.second || {};
    const roundEmis = design === 'cargo' && S.rounds ? emission * S.rounds.share : 0;
    const rigEmis = emission - roundEmis;
    const Y = design === 'cargo' && S.yield ? S.yield.share : 0;     // share of burn flows paid to rigs in OKB instead
    const resShare = design === 'cargo' && S.floor ? S.floor.reserve : 0; // share of mint OKB kept as redemption reserve
    const polShare = P.toCargoPol - resShare;
    let yieldToday = 0;
    const px = price() || P.mintPrice0 * 2 / 600; // bootstrap guess before pool exists
    const mintPrice = P.mintPrice0 * (1 + minted / P.curveM);
    // rig economics for a NEW miner: CARGO/day per OKB spent
    const powerPerOkb = 1 / mintPrice;
    const newPowerRef = powerPerOkb; // 1 OKB of new rig
    const share = newPowerRef / (power + newPowerRef);
    const okbPerDay = share * rigEmis * px * (1 - P.poolFee) + share * yieldPrev; // + real fee yield in OKB
    const fabFee = design === 'cargo' && S.orders ? S.orders.fabFee : 0;
    const roi = okbPerDay * 365 / (1 + fabFee); // yearly OKB per 1 OKB spent (mint + fab fee)
    const pull = Math.min(3, Math.max(0.15, roi / P.roiRef));
    const spend = P.D0 * Math.exp(-t / P.tau) * pull;

    mintTotal += spend;
    minted += spend / mintPrice;
    power += spend * powerPerOkb;

    if (design === 'fabx') {
      teamOkb += spend;
      if (t === 0) po = 0.5 * spend, teamOkb -= 0.5 * spend; // team seeds pool once with half of day-0 mint
    } else {
      teamOkb += spend * P.team;
      // POL: half of the slice buys CARGO, then both sides are added at the new price
      const slice = spend * polShare;
      reserve += spend * resShare;
      if (po === 0) { po += slice; } else {
        const got = buyCargo(slice / 2);
        const addO = Math.min(slice / 2, got * po / pc); // pair at the post-buy marginal price
        pc += got; po += addO;
        bemVault += slice / 2 - addO; // unpaired OKB goes to the BEM/OKB slice
      }
      bemVault += spend * P.toBemVault;
      const vaultUsd = bemVault * OKB_USD;
      const capShare = P.bemPoolFeesUsd * vaultUsd / (vaultUsd + P.bemPoolTvlUsd) / OKB_USD;
      const bemFees = Math.min(bemVault * P.bemVaultApr / 365, capShare);
      const c = buyCargo(bemFees * P.bemFeeSplit.cargoBurn * (1 - Y)); burned += c; // bought CARGO leaves pool and is burned
      yieldToday += bemFees * P.bemFeeSplit.cargoBurn * Y;
      bemBoughtOkb += bemFees * P.bemFeeSplit.bemBuy;
      teamOkb += bemFees * P.bemFeeSplit.team;
    }

    // ---- second demand sources (Cargo design only) ----
    let fuelBurn = 0;
    if (design === 'cargo') {
      // D) ORE-style rounds: players deploy OKB on a 25-tile grid; losing tiles pay `fee` -> buyback/BEM POL/team.
      // Deployed OKB/day = alpha * (CARGO paid to rounds in OKB) / fee, times a novelty factor, capped by market size.
      if (S.rounds) {
        const R = S.rounds;
        const pxNow = price() || px;
        const novelty = 0.5 + 0.5 * Math.exp(-t / 30);
        const deployed = Math.min(R.capUsd / OKB_USD, R.alpha * roundEmis * pxNow / R.fee) * novelty;
        const fee = deployed * (24 / 25) * R.fee;
        const c = buyCargo(fee * R.split.burn); burned += c;
        bemVault += fee * R.split.bemPol;
        teamOkb += fee * R.split.team;
        roundDeployed += deployed; roundFees += fee;
      }
      // D') production orders: no wager, no randomness. Rigs choose a tile; each tile has a fixed CARGO budget, paid pro-rata.
      // All emission still goes to rig owners (ROI unchanged). Cash comes from a fixed OKB fab/service fee on top of each mint.
      if (S.orders) {
        const O = S.orders;
        const fee = spend * O.fabFee;
        const c = buyCargo(fee * O.split.burn); burned += c;
        bemVault += fee * O.split.bemPol;
        teamOkb += fee * O.split.team;
        roundFees += fee;
      }
      // A) lock CARGO to boost BEM/OKB vault yield: outside depositors need r * deposit (USD) in locked CARGO
      if (S.lock) {
        const ext = S.lock.maxUsd * (1 - Math.exp(-t / S.lock.ramp));
        const need = S.lock.ratio * ext / OKB_USD; // OKB-equivalent of CARGO to hold
        const add = Math.max(0, need - lockedOkbValue);
        if (add > 0) { const c = buyCargo(add); locked += c; lockedOkbValue += add; }
      }
      // B) seasons: every `every` days a new processor opens; half of its mint price is paid in CARGO and burned
      if (S.season && t >= S.season.every) {
        const age = t % S.season.every;
        const pulse = P.D0 * S.season.size * Math.exp(-age / P.tau);
        const c = buyCargo(pulse * 0.5); burned += c;
        const rest = pulse * 0.5;
        mintTotal += pulse; teamOkb += rest * P.team;
        reserve += rest * resShare;
        const got = buyCargo(rest * polShare / 2);
        const addO = Math.min(rest * polShare / 2, got * po / pc);
        pc += got; po += addO;
        bemVault += rest * P.toBemVault + (rest * polShare / 2 - addO);
      }
      // C) fuel: share of each day's emission is burned to keep rigs at full power (miners receive less)
      if (S.fuel) fuelBurn = emission * S.fuel;
    }

    // miners sell part of today's emission
    supply += emission;
    burned += fuelBurn;
    const out = sellCargo((emission - fuelBurn) * P.sellShare);
    // pool fees (on organic volume) -> for Cargo: buyback & burn; for FabX: stay with LPs
    const tvlOkb = 2 * po;
    const fees = Math.min(tvlOkb * P.turnover, P.maxVolUsd / OKB_USD) * P.poolFee;
    if (design === 'cargo') {
      const b = buyCargo(fees * P.cargoFeeSplit.burn * (1 - Y)); burned += b;
      yieldToday += fees * P.cargoFeeSplit.burn * Y;
      yieldTotal += yieldToday; yieldPrev = yieldToday;
      // F) floor: CARGO redeemable for reserve / circulating. Below it, arbitrage buys from the pool and redeems (burn).
      if (S.floor && reserve > 0) {
        const circ = supply - burned - pc;
        floorPx = circ > 0 ? reserve / circ : 0;
        if (price() < floorPx) {
          const target = Math.sqrt(po * pc * floorPx); // OKB reserve of pool at price = floor
          const x = Math.min(target - po, reserve);
          const got = buyCargo(x); burned += got; reserve -= x;
        }
      }
      teamOkb += fees * P.cargoFeeSplit.team;
    }
    rows.push({ t, px: price(), roundFeesUsd: roundFees * OKB_USD, roundDeployedUsd: roundDeployed * OKB_USD, polBemTotalUsd: bemVault * OKB_USD, polCargoOkbUsd: po * OKB_USD, spend, mintPrice, roi, tvlUsd: tvlOkb * OKB_USD, yieldUsd: yieldTotal * OKB_USD, floorUsd: floorPx * OKB_USD, reserveUsd: reserve * OKB_USD, teamUsd: teamOkb * OKB_USD, burned, supply, bemUsd: bemBoughtOkb * OKB_USD, polBemUsd: bemVault * OKB_USD, minerSellUsd: out * OKB_USD });
  }
  return rows;
}

const scenarios = {
  bear: { D0: 120, tau: 5, turnover: 0.3 },
  base: {},
  bull: { D0: 600, tau: 12, turnover: 1.5 },
};

const fmt = (n, d = 0) => n.toLocaleString('en-US', { maximumFractionDigits: d, minimumFractionDigits: d });

// Second-demand comparison: `node tools/cargo-sim-v0.js 90 second`
if (process.argv[3] === 'second') {
  const options = {
    'none': {},
    'A lock-boost': { lock: { maxUsd: 300000, ramp: 20, ratio: 0.2 } },
    'B seasons/30d': { season: { every: 30, size: 0.6 } },
    'C fuel 25%': { fuel: 0.25 },
    'A+B': { lock: { maxUsd: 300000, ramp: 20, ratio: 0.2 }, season: { every: 30, size: 0.6 } },
    'D rounds': { rounds: true },
    'B+D': { season: { every: 30, size: 0.6 }, rounds: true },
    "D' orders": { orders: true },
    "B+D'": { season: { every: 30, size: 0.6 }, orders: true },
    "B+D'+Y": { season: { every: 30, size: 0.6 }, orders: true, yield: { share: 0.5 } },
    "B+D'+F": { season: { every: 30, size: 0.6 }, orders: true, floor: { reserve: 0.15 } },
    "B+D'+Y+F": { season: { every: 30, size: 0.6 }, orders: true, yield: { share: 0.5 }, floor: { reserve: 0.15 } },
    "Y30F0": { season: { every: 30, size: 0.6 }, orders: true, yield: { share: 0.3 },  },
    "Y30F5": { season: { every: 30, size: 0.6 }, orders: true, yield: { share: 0.3 }, floor: { reserve: 0.05 } },
    "Y30F10": { season: { every: 30, size: 0.6 }, orders: true, yield: { share: 0.3 }, floor: { reserve: 0.1 } },
    "Y50F0": { season: { every: 30, size: 0.6 }, orders: true, yield: { share: 0.5 },  },
    "Y50F5": { season: { every: 30, size: 0.6 }, orders: true, yield: { share: 0.5 }, floor: { reserve: 0.05 } },
    "Y50F10": { season: { every: 30, size: 0.6 }, orders: true, yield: { share: 0.5 }, floor: { reserve: 0.1 } },
  };
  const ordersCfg = { fabFee: 0.05, split: { burn: 0.45, bemPol: 0.45, team: 0.10 } };
  const roundCfg = cap => ({ share: 0.5, fee: 0.10, alpha: 1.2, capUsd: cap, split: { burn: 0.45, bemPol: 0.45, team: 0.10 } });
  const roundCap = { bear: 15000, base: 50000, bull: 150000 };
  const only = process.argv[4] ? process.argv[4].split(',') : null;
  console.log('scenario | option | peak $ | day30 $ | day60 $ | end $ | end vs peak | team $ | burned | round/fab fees $ | BEM/OKB POL $ | OKB locked in CARGO pool $ | rig real yield $ | floor $ | reserve $');
  for (const [sn, sv] of Object.entries(scenarios)) {
    for (const [on, ov0] of Object.entries(options)) {
      if (only && !only.includes(on.split(' ')[0])) continue;
      const ov = { ...ov0, ...(ov0.rounds ? { rounds: roundCfg(roundCap[sn]) } : {}), ...(ov0.orders ? { orders: ordersCfg } : {}) };
      const r = run('cargo', { ...sv, second: ov });
      const peak = Math.max(...r.map(x => x.px)), e = r[r.length - 1];
      const at = d => (r[d - 1] ? fmt(r[d - 1].px * OKB_USD, 3) : '-');
      console.log([sn, on.padEnd(13), fmt(peak * OKB_USD, 3), at(30), at(60), fmt(e.px * OKB_USD, 3), fmt((e.px / peak - 1) * 100) + '%', fmt(e.teamUsd), fmt(e.burned), fmt(e.roundFeesUsd), fmt(e.polBemTotalUsd), fmt(e.polCargoOkbUsd), fmt(e.yieldUsd), fmt(e.floorUsd, 3), fmt(e.reserveUsd)].join(' | '));
    }
  }
  process.exit(0);
}

for (const [name, over] of Object.entries(scenarios)) {
  console.log(`\n=== ${name.toUpperCase()} ===`);
  console.log('design | day | CARGO $ | pool TVL $ | mint OKB/d | rig ROI/yr | team $ cum | burned | BEM bought $ | BEM/OKB POL $');
  for (const d of ['fabx', 'cargo']) {
    const r = run(d, over);
    for (const t of [0, 6, 13, 29, DAYS - 1]) {
      const x = r[t]; if (!x) continue;
      console.log([d.padEnd(5), String(t + 1).padStart(3), fmt(x.px * OKB_USD, 4), fmt(x.tvlUsd), fmt(x.spend, 1), fmt(x.roi * 100) + '%', fmt(x.teamUsd), fmt(x.burned), fmt(x.bemUsd), fmt(x.polBemUsd)].join(' | '));
    }
    const peak = Math.max(...r.map(x => x.px)), last = r[r.length - 1].px;
    console.log(`  ${d}: price peak→end ${fmt(peak * OKB_USD, 4)} → ${fmt(last * OKB_USD, 4)} (${fmt((last / peak - 1) * 100, 0)}%)`);
  }
}
