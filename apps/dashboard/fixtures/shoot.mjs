// Screenshots the four pages against the dev fixtures, at the design's viewport,
// and reports every console error, page error and failed request.
//
// PLAYWRIGHT IS DELIBERATELY NOT A DEPENDENCY. `npm run build` is the only test
// this repository has, and adding a browser download to it for a script nobody
// runs in CI would be a poor trade. So this asks for it explicitly rather than
// being quietly unrunnable - the same reason lint-repo.sh SKIPs loudly without
// shellcheck instead of reporting that it passed.
//
//   npm i --no-save --no-package-lock playwright
//   npx playwright install chromium
//   npm run dev &
//   node fixtures/shoot.mjs [outDir]
//
// The fixture host is deliberately unhealthy, so ONE 404 is expected: the
// missing-poster path that exists to put the fallback tile on screen.
let chromium;
try {
  ({ chromium } = await import("playwright"));
} catch {
  console.error(
    "fixtures/shoot.mjs needs playwright, which is not a dependency of this app.\n" +
      "  npm i --no-save --no-package-lock playwright && npx playwright install chromium",
  );
  process.exit(2);
}

const out = process.argv[2] ?? "/tmp";
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1360, height: 860 } });

const problems = [];
page.on("console", (m) => {
  if (m.type() === "error") problems.push(`console: ${m.text()}`);
});
page.on("pageerror", (e) => problems.push(`pageerror: ${e.message}`));
page.on("requestfailed", (r) => problems.push(`requestfailed: ${r.url()} ${r.failure()?.errorText}`));

for (const route of ["home", "library", "system", "services"]) {
  await page.goto(`http://localhost:5173/${route}`, { waitUntil: "networkidle" });
  await page.waitForTimeout(700);
  await page.screenshot({ path: `${out}/${route}.png` });
  const text = (await page.locator("body").innerText()).replace(/\s+/g, " ").trim();
  console.log(`\n=== /${route}  (${text.length} chars of text)`);
  console.log(text.slice(0, 700));
}

console.log(`\n--- ${problems.length} problem(s)`);
for (const p of [...new Set(problems)].slice(0, 15)) console.log(`  ${p}`);

await browser.close();
process.exit(problems.length ? 1 : 0);
