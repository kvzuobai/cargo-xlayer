// UI end-to-end (Voyage / CargoMiner v2) on a local anvil fork: node tools/e2e.js  (needs anvil :8545 with Cargo deployed, server :5190)
// Unlocked anvil accounts: ?acct=2 loads/claims/charters, ?acct=3 buys a bill. Steps: mint, tape out, load (B05 + B20), warp, claim,
// Express seat + claim, charter (WOKB) + token credit, list + buy bill, sweep voyage fees, redeem. Saves shots/<tab>-<w>.png.
const path = require("path"), fs = require("fs");
const puppeteer = require(process.env.PUPPETEER || "puppeteer-core");
const CHROME = process.env.CHROME || "C:/Program Files/Google/Chrome/Application/chrome.exe";
const BASE = "http://localhost:5190/?rpc=http://127.0.0.1:8545&acct=";
const WOKB = "0xe538905cf8410324e03A5A23C1c177a474D59b2b";
const rpc = (method, params = []) => fetch("http://127.0.0.1:8545", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) }).then(r => r.json());
const sleep = ms => new Promise(r => setTimeout(r, ms));
const warp = async s => { await rpc("evm_increaseTime", [s]); await rpc("evm_mine") };
(async () => {
  const b = await puppeteer.launch({ executablePath: CHROME, headless: "new" });
  const p = await b.newPage(); await p.setViewport({ width: 1280, height: 900 });
  p.on("dialog", d => d.accept()); p.on("pageerror", e => console.log("PAGE ERROR", e.message));
  const text = sel => p.$eval(sel, e => e.textContent.trim());
  const open = async (acct, view) => { await p.goto(BASE + acct + "#" + view, { waitUntil: "networkidle0" }); await sleep(2500); await p.click("#conn"); await sleep(3500) };
  const set = (sel, v) => p.$eval(sel, (e, v) => { e.value = v; e.dispatchEvent(new Event("input")); e.dispatchEvent(new Event("change")) }, v);
  // click, then wait for "Confirmed · <label>" (last tx of the action) or a failure
  const act = async (sel, label) => {
    await p.$eval("#toast", e => e.textContent = ""); await p.click(sel);
    for (let i = 0; i < 60; i++) {
      await sleep(500); const m = await text("#toast");
      if (/Failed/.test(m)) throw new Error(sel + " → " + m);
      if (m.includes("Confirmed · " + label)) { console.log(sel, "→", m); await sleep(1200); return }
    }
    throw new Error(sel + " timeout: " + await text("#toast"));
  };
  const me = (await rpc("eth_accounts")).result;

  // 1. load two circuits: B05 (Cargo) and B20
  await open(2, "load");
  for (const [q, berth] of [[120, 4], [60, 19]]) {
    await set("#qty", String(q)); await sleep(300);
    await act("#bMint", "Mint");
    await act("#bTape", "Tape out"); await sleep(800);
    await p.click(`#miniBerths [data-berth="${berth}"]`); await sleep(1800);
    console.log("stake info:", await text("#sInfo"));
    await act("#bStake", "Load");
  }
  // 2. sail ~20 voyages (enough CARGO for a 10 CARGO seat), claim
  await warp(6020); await open(2, "ship");
  console.log("voyage:", await text("#vy"));
  console.log("rigs:", await text("#rigs"));
  await act("#bClaim", "Claim all");

  // 3. Express: seat for the next block, then claim after it ends
  await open(2, "express");
  console.log("express:", await text("#xcells"));
  console.log("seat info:", await text("#xInfo"));
  await act("#bSeat", "Buy seat");
  console.log("blocks:", await text("#xblocks"));
  await warp(7300); await open(2, "express");
  await act("#bXclaim", "Claim all");

  // 4. charter B05 with WOKB for 7 days; claim the bill there so the token is credited
  await rpc("eth_sendTransaction", [{ from: me[2], to: WOKB, value: "0x" + (5n * 10n ** 18n).toString(16), data: "0xd0e30db0" }]);
  await open(2, "charter");
  await p.click('#chBerths [data-chb="4"]'); await sleep(800);
  await set("#chTok", WOKB); await set("#chAmt", "2"); await sleep(1800);
  console.log("charter info:", await text("#chInfo"));
  await act("#bCharter", "Charter B05");
  await warp(1200); await open(2, "ship");
  await act("#bClaim", "Claim all");
  await open(2, "charter");
  console.log("credits:", await text("#creds"));
  await act("[data-ctok]", "Claim");

  // 5. bills: acct 2 lists bill #0, acct 3 buys it
  await open(2, "bills");
  await set("#lp0", "0.01"); await act('[data-list="0"]', "List #0");
  await open(3, "bills");
  console.log("for sale:", await text("#sale"));
  await act('[data-buy="0"]', "Buy #0");

  // 6. keeper: voyage fees (charter + bill fee)
  await open(2, "dock");
  await p.evaluate(() => document.querySelector("details.adv").open = true); // collapsed by default
  console.log("keeper:", await text("#keep"));
  await act('[data-k="voy"]', "miner.sweepVoyageFees");

  // 7. reserve
  await open(2, "reserve");
  await p.click("#bMax"); await sleep(1500); console.log("quote:", await text("#rq"));
  await act("#bRedeem", "Redeem");

  fs.mkdirSync(path.join(__dirname, "..", "shots"), { recursive: true });
  for (const w of [1280, 390]) for (const v of ["dock", "load", "ship", "express", "charter", "bills", "reserve"]) {
    await p.setViewport({ width: w, height: 900 }); await open(2, v);
    const over = await p.evaluate(() => document.documentElement.scrollWidth - innerWidth);
    await p.screenshot({ path: path.join(__dirname, "..", "shots", `${v}-${w}.png`), fullPage: true }); console.log(v, w, "overflow", over);
  }
  await b.close();
})().catch(e => { console.error("E2E FAIL:", e.message); process.exit(1) });
