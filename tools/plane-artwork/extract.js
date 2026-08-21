// Pulls the artwork out of the source SVGs as flat, transform-free path data.
const fs = require('fs');
const path = require('path');
const svgpath = require('svgpath');
const { chromium } = require('playwright');
// Where the two upstream marker repos have been cloned. See README.md.
const ROOT = process.env.MARKER_SOURCES || path.join(__dirname, 'sources');

const SOURCES = JSON.parse(fs.readFileSync(__dirname + '/sources.json', 'utf8'));

(async () => {
  const browser = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome' });
  const page = await browser.newPage();
  const out = {};

  for (const [key, rel] of Object.entries(SOURCES)) {
    const file = path.join(ROOT, rel);
    const svg = fs.readFileSync(file, 'utf8');
    await page.setContent(`<body style="margin:0">${svg}</body>`);
    const parts = await page.evaluate(() => {
      const root = document.querySelector('svg');
      const geo = root.querySelectorAll('path,rect,circle,ellipse,polygon,polyline,line');
      const result = [];
      for (const el of geo) {
        const cs = getComputedStyle(el);
        if (cs.display === 'none' || cs.visibility === 'hidden') continue;
        let d = null;
        const n = el.tagName.toLowerCase();
        const f = a => parseFloat(el.getAttribute(a) || 0);
        if (n === 'path') d = el.getAttribute('d');
        else if (n === 'rect') {
          const [x, y, w, h] = ['x','y','width','height'].map(f);
          const rx = Math.min(f('rx') || f('ry') || 0, w / 2);
          const ry = Math.min(f('ry') || f('rx') || 0, h / 2);
          d = rx || ry
            ? `M${x+rx},${y}H${x+w-rx}A${rx},${ry} 0 0 1 ${x+w},${y+ry}V${y+h-ry}A${rx},${ry} 0 0 1 ${x+w-rx},${y+h}H${x+rx}A${rx},${ry} 0 0 1 ${x},${y+h-ry}V${y+ry}A${rx},${ry} 0 0 1 ${x+rx},${y}Z`
            : `M${x},${y}H${x+w}V${y+h}H${x}Z`;
        } else if (n === 'circle' || n === 'ellipse') {
          const cx = f('cx'), cy = f('cy');
          const rx = n === 'circle' ? f('r') : f('rx');
          const ry = n === 'circle' ? f('r') : f('ry');
          d = `M${cx-rx},${cy}A${rx},${ry} 0 1 0 ${cx+rx},${cy}A${rx},${ry} 0 1 0 ${cx-rx},${cy}Z`;
        } else if (n === 'polygon' || n === 'polyline') {
          const pts = (el.getAttribute('points') || '').trim().split(/[\s,]+/).map(Number);
          if (pts.length < 4) continue;
          d = 'M' + pts[0] + ',' + pts[1];
          for (let i = 2; i < pts.length; i += 2) d += `L${pts[i]},${pts[i+1]}`;
          if (n === 'polygon') d += 'Z';
        } else if (n === 'line') {
          d = `M${f('x1')},${f('y1')}L${f('x2')},${f('y2')}`;
        }
        if (!d) continue;
        const m = el.getCTM();
        result.push({
          d,
          matrix: [m.a, m.b, m.c, m.d, m.e, m.f],
          fill: cs.fill,
          rule: cs.fillRule || 'nonzero',
          stroke: cs.stroke,
          strokeWidth: parseFloat(cs.strokeWidth) || 0,
        });
      }
      return result;
    });

    out[key] = parts.map(p => ({
      d: svgpath(p.d).matrix(p.matrix).unshort().unarc().abs().round(3).toString(),
      fill: p.fill,
      rule: p.rule,
      stroke: p.stroke,
      strokeWidth: p.strokeWidth,
    }));
    process.stdout.write(`${key}:${out[key].length} `);
  }

  await browser.close();
  fs.writeFileSync(__dirname + '/artwork.json', JSON.stringify(out, null, 1));
  console.log('\nwrote artwork.json');
})();
