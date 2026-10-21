// Creo: mem_1Cft9Di4PSzVCwhu9BCbA4
import {test} from 'node:test';
import assert from 'node:assert/strict';
const api = await import('./logo-model.mjs').catch(e => { if (e.code === 'ERR_MODULE_NOT_FOUND') return {}; throw e; });

test('billboard starts with the existing 4 by 3 layout and one mint tile', () => {
  assert.equal(typeof api.tiles, 'function');
  const tiles = api.tiles(api.defaults);
  assert.equal(tiles.length, 12);
  assert.deepEqual(tiles.filter(t => t.lit).map(t => [t.column,t.row]), [[1,1]]);
  assert.equal(api.defaults.color, '#61c594');
  assert.ok(Math.abs(tiles[0].x - 212) < 0.001);
  assert.ok(Math.abs(tiles.at(-1).x + tiles.at(-1).width - 788) < 0.001);
});

test('SVG round trip retains every editable value and regenerates safe artwork', () => {
  assert.equal(typeof api.writeSvg, 'function');
  const model = {...api.defaults, gap:0.5, radius:0.4, depth:45, litColumn:3, litRow:0, roughness:0.9, lightAngle:-50};
  const svg = api.writeSvg(model);
  assert.deepEqual(api.readModel(svg), model);
  assert.equal(api.updateLogo(svg), svg);
  assert.equal((svg.match(/data-tile=/g)||[]).length, 12);
  assert.equal((svg.match(/data-lit="true"/g)||[]).length, 1);
  assert.ok(!api.updateLogo(svg.replace('</svg>','<script>alert(1)</script></svg>')).includes('<script'));
});

test('invalid imported parameters are rejected before rendering or saving', () => {
  assert.equal(typeof api.writeSvg, 'function');
  for (const patch of [{gap:NaN},{litRow:3},{litColumn:1.5},{color:'url(https://example.com)'},{depth:-1},{version:2},{surprise:true}]) {
    assert.throws(() => api.writeSvg({...api.defaults,...patch}));
  }
  assert.throws(() => api.readModel('<svg/>'));
  for (const gap of [0,0.8]) for (const radius of [0,0.5]) {
    const tiles=api.tiles({...api.defaults,gap,radius});
    assert.ok(tiles.every(t=>t.width>0 && t.height>0 && t.radius<=Math.min(t.width,t.height)/2));
  }
});

test('every initial slider value is representable without browser rounding',()=>{
  for(const [key,f] of Object.entries(api.fields)){
    if(f.type)continue;
    const steps=(api.defaults[key]-f.min)/f.step;
    assert.ok(Math.abs(steps-Math.round(steps))<1e-8,key+' rounds on mount');
  }
});
