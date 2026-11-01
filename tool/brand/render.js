const { chromium } = require('playwright');
const fs = require('fs');
(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1024, height: 1024 } });
  for (const kind of process.argv.slice(2)) {
    const svg = fs.readFileSync(`${kind}.svg`, 'utf8');
    await page.setContent(`<html><body style="margin:0;background:transparent">${svg}</body></html>`);
    await page.locator('svg').screenshot({ path: `${kind}.png`, omitBackground: true });
  }
  await browser.close();
})();
