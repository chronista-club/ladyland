export const defaults = Object.freeze({version:1, gap:0.26, radius:0.24, inset:0.14,
  plateRadius:0.2246, depth:18, litColumn:1, litRow:1, color:'#61c594', background:'#070b14',
  dim:0.2, glow:0.85, roughness:0.65, lightAngle:-35, lightIntensity:3});

export const fields = {
  gap:{label:'タイルの間隔',min:0,max:0.8,step:0.01,group:'shape'},
  radius:{label:'タイルの丸み',min:0,max:0.5,step:0.01,group:'shape'},
  inset:{label:'盤面の余白',min:0.05,max:0.3,step:0.01,group:'shape'},
  plateRadius:{label:'盤面の丸み',min:0,max:0.5,step:0.0001,group:'shape'},
  depth:{label:'厚み',min:0,max:80,step:1,group:'shape'},
  litColumn:{label:'点灯する列',min:0,max:3,step:1,group:'position'},
  litRow:{label:'点灯する行',min:0,max:2,step:1,group:'position'},
  color:{label:'点灯色',type:'color',group:'color'},
  background:{label:'盤面の色',type:'color',group:'color'},
  dim:{label:'消灯時の明るさ',min:0,max:0.6,step:0.01,group:'color'},
  glow:{label:'発光',min:0,max:1.5,step:0.01,group:'color'},
  roughness:{label:'マットさ',min:0.1,max:1,step:0.01,group:'light'},
  lightAngle:{label:'光の向き',min:-180,max:180,step:1,group:'light'},
  lightIntensity:{label:'光の強さ',min:0.2,max:6,step:0.1,group:'light'},
};

export function validate(model) {
  if (!model || model.version!==1 || Object.keys(model).sort().join()!==Object.keys(defaults).sort().join()) throw new Error('Ladyland の編集用SVGではありません');
  for (const [key,f] of Object.entries(fields)) {
    const v=model[key];
    if (f.type==='color' ? typeof v!=='string'||!/^#[a-f0-9]{6}$/i.test(v) : !Number.isFinite(v)||v<f.min||v>f.max||f.step===1&&!Number.isInteger(v)) throw new Error(f.label+'の値が不正です');
  }
  return {...model};
}

export function tiles(value) {
  const m=validate(value), span=800*(1-2*m.inset), start=100+800*m.inset;
  const width=span/(4+3*m.gap), height=span/(3+2*m.gap);
  return Array.from({length:12},(_,i)=>({column:i%4,row:Math.floor(i/4),
    x:start+(i%4)*width*(1+m.gap), y:start+Math.floor(i/4)*height*(1+m.gap),
    width,height,radius:Math.min(width,height)*m.radius,lit:i%4===m.litColumn&&Math.floor(i/4)===m.litRow}));
}

const num=v=>Number(v.toFixed(5));
export function writeSvg(value) {
  const m=validate(value), cells=tiles(m);
  const rect=t=>`x="${num(t.x)}" y="${num(t.y)}" width="${num(t.width)}" height="${num(t.height)}" rx="${num(t.radius)}"`;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 1000" width="1000" height="1000">
<title>Ladyland — billboard</title>
<metadata id="ladyland-logo-model">${JSON.stringify(m)}</metadata>
<defs><filter id="glow" x="-100%" y="-100%" width="300%" height="300%"><feGaussianBlur stdDeviation="${num(cells[0].width*0.18)}"/></filter></defs>
<rect x="100" y="100" width="800" height="800" rx="${num(800*m.plateRadius)}" fill="${m.background}" stroke="${m.color}" stroke-opacity="0.18" stroke-width="6"/>
${cells.map(t=>`${t.lit?`<rect ${rect(t)} fill="${m.color}" opacity="${m.glow}" filter="url(#glow)"/>\n`:''}<rect data-tile="${t.column},${t.row}" data-lit="${t.lit}" ${rect(t)} fill="${m.color}" fill-opacity="${t.lit?1:m.dim}"/>`).join('\n')}
</svg>\n`;
}

export function readModel(svg) {
  if (typeof svg!=='string'||svg.length>1024*1024) throw new Error('SVGのサイズが不正です');
  const match=svg.match(/<metadata id="ladyland-logo-model">([^<]+)<\/metadata>/);
  if (!match) throw new Error('Ladyland の編集用SVGではありません');
  return validate(JSON.parse(match[1]));
}
export const updateLogo=svg=>writeSvg(readModel(svg));
