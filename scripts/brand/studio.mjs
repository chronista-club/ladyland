import * as THREE from 'three';
import {OrbitControls} from 'three/addons/controls/OrbitControls.js';
import {fields,readModel,writeSvg,tiles} from './logo-model.mjs';

const $=id=>document.getElementById(id);
const initial=JSON.parse($('studio-data').textContent);
let model=readModel(initial.source), saved=writeSvg(model), revision=initial.revision;
let mode='2d', transparent=false, saving=false;
let renderer,scene,camera,orbit,group,key;
const draftKey='ladyland-logo:'+location.pathname;
try {const draft=JSON.parse(localStorage.getItem(draftKey));if(draft?.revision===revision)model=readModel(draft.source);}catch{}
const status=text=>$('status').textContent=text;
const dirty=()=>writeSvg(model)!==saved;
function rememberDraft(){try{localStorage.setItem(draftKey,JSON.stringify({revision,source:writeSvg(model)}));}catch{}}
function announce(){status(dirty()?'調整中 · 保存すると次回もこの形から再開できます。':'保存済み · タイルを出発点に、形を調整できます。');$('save').disabled=saving||!dirty();}
function set(patch){model=readModel(writeSvg({...model,...patch}));rememberDraft();draw();announce();}
function mount(){
  for(const id of ['shape','color','light'])$(id+'-controls').replaceChildren();
  for(const [name,f]of Object.entries(fields)){
    if(f.group==='position')continue;
    const label=document.createElement('label');label.className='field';
    const head=document.createElement('span');head.className='field-head';
    const title=document.createElement('span');title.textContent=f.label;
    const value=document.createElement('output');value.textContent=model[name];head.append(title,value);
    const input=document.createElement('input');input.type=f.type||'range';input.name=name;input.setAttribute('aria-label',f.label);
    if(!f.type){input.min=f.min;input.max=f.max;input.step=f.step;}input.value=model[name];
    input.oninput=()=>{const v=f.type?input.value:input.valueAsNumber;value.textContent=v;set({[name]:v});};
    label.append(head,input);$(f.group+'-controls').append(label);
  }
  $('tile-controls').replaceChildren();
  for(let i=0;i<12;i++){
    const b=document.createElement('button');b.textContent=i+1;b.setAttribute('aria-label',`${Math.floor(i/4)+1}行 ${i%4+1}列を点灯`);
    b.onclick=()=>set({litColumn:i%4,litRow:Math.floor(i/4)});$('tile-controls').append(b);
  }
}
function draw(){
  // Only the validated, regenerated SVG is inserted; imported markup is never displayed.
  const svg=writeSvg(model);$('flat').innerHTML=svg;
  $('sizes').replaceChildren();
  for(const size of [16,32,64]){const item=document.createElement('div');item.className='preview-size';item.innerHTML=svg;const s=item.querySelector('svg');s.style.width=size+'px';s.style.height=size+'px';const caption=document.createElement('span');caption.textContent=size;item.append(caption);$('sizes').append(item);}
  [...$('tile-controls').children].forEach((b,i)=>b.setAttribute('aria-pressed',String(i%4===model.litColumn&&Math.floor(i/4)===model.litRow)));
  if(renderer)rebuild();
}
function shape(x,y,w,h,r){
  const s=new THREE.Shape();s.moveTo(x+r,y);s.lineTo(x+w-r,y);s.quadraticCurveTo(x+w,y,x+w,y+r);s.lineTo(x+w,y+h-r);s.quadraticCurveTo(x+w,y+h,x+w-r,y+h);s.lineTo(x+r,y+h);s.quadraticCurveTo(x,y+h,x,y+h-r);s.lineTo(x,y+r);s.quadraticCurveTo(x,y,x+r,y);return s;
}
function slab(x,y,w,h,r,depth,color,z,emissive=0){
  const outline=shape((x-500)/1000,(500-y-h)/1000,w/1000,h/1000,r/1000);
  const geometry=new THREE.ExtrudeGeometry(outline,{depth:Math.max(depth,0.1)/1000,bevelEnabled:false,curveSegments:20,steps:1});
  const material=new THREE.MeshStandardMaterial({color,roughness:model.roughness,metalness:0,emissive:color,emissiveIntensity:emissive});
  const mesh=new THREE.Mesh(geometry,material);mesh.position.z=z;group.add(mesh);
}
function rebuild(){
  for(const mesh of [...group.children]){mesh.geometry.dispose();mesh.material.dispose();group.remove(mesh);}
  slab(100,100,800,800,800*model.plateRadius,model.depth,model.background,-model.depth/1000);
  const dark=new THREE.Color(model.background),mint=new THREE.Color(model.color);
  for(const t of tiles(model))slab(t.x,t.y,t.width,t.height,t.radius,model.depth*0.3,t.lit?mint:dark.clone().lerp(mint,model.dim),0.001,t.lit?model.glow:0);
  const a=model.lightAngle*Math.PI/180;key.position.set(Math.sin(a)*3,2,Math.cos(a)*3);key.intensity=model.lightIntensity;
  render();
}
function render(){renderer?.render(scene,camera);}
function resize(){if(!renderer)return;const w=$('viewport').clientWidth,h=$('viewport').clientHeight;if(!w||!h)return;renderer.setSize(w,h,false);const half=Math.max(.55,.55/(w/h));camera.left=-half*w/h;camera.right=half*w/h;camera.top=half;camera.bottom=-half;camera.updateProjectionMatrix();render();}
function init3d(){
  if(renderer)return;
  renderer=new THREE.WebGLRenderer({canvas:$('scene'),antialias:true,alpha:true,preserveDrawingBuffer:true});renderer.setPixelRatio(Math.min(devicePixelRatio,2));
  scene=new THREE.Scene();camera=new THREE.OrthographicCamera(-1,1,1,-1,.01,30);camera.position.set(.6,.4,2.4);camera.lookAt(0,0,0);
  group=new THREE.Group();scene.add(group);scene.add(new THREE.HemisphereLight(0xffffff,0x324e3d,2));key=new THREE.DirectionalLight(0xffffff,model.lightIntensity);scene.add(key);
  orbit=new OrbitControls(camera,$('scene'));orbit.enablePan=false;orbit.minZoom=.6;orbit.maxZoom=2.5;orbit.addEventListener('change',render);
  new ResizeObserver(resize).observe($('viewport'));rebuild();resize();
}
function view(next){
  try{if(next==='3d')init3d();mode=next;$('flat').hidden=next!=='2d';$('scene').hidden=next!=='3d';$('reset-camera').hidden=next!=='3d';
    for(const v of ['2d','3d'])$('view-'+v).setAttribute('aria-pressed',String(v===next));$('hint').textContent=next==='3d'?'ドラッグで回転 ／ スクロールで拡大':'4 × 3 ／ 一灯の billboard';resize();
  }catch(e){status('3Dを開始できません。2Dは引き続き使えます。'+e.message);}
}
function download(blob,name){const a=document.createElement('a');const url=URL.createObjectURL(blob);a.href=url;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(url),30000);}
async function api(path,body,type='application/json'){
  const response=await fetch(initial.apiBase+path,{method:'POST',headers:{'Content-Type':type,'X-Ladyland-Token':initial.token},body});
  const data=await response.json();if(!response.ok)throw new Error(data.error);return data;
}
$('save').onclick=async()=>{
  const source=writeSvg(model);
  if(!initial.apiBase){download(new Blob([source],{type:'image/svg+xml'}),'ladyland-source.svg');status('編集用SVGを書き出しました。再開にはこのSVGを読み込んでください。');return;}
  saving=true;announce();
  try{const result=await api('/save',JSON.stringify({svg:source,revision}));revision=result.revision;saved=source;rememberDraft();saving=false;announce();}
  catch(e){saving=false;announce();status(e.message);}
};
$('svg-export').onclick=()=>download(new Blob([writeSvg(model)],{type:'image/svg+xml'}),'ladyland-source.svg');
$('import').onchange=async e=>{const file=e.target.files[0];if(!file)return;try{if(file.size>1024*1024)throw new Error('SVGが大きすぎます');model=readModel(await file.text());mount();draw();rememberDraft();announce();}catch(err){status(err.message);}e.target.value='';};
$('revert').onclick=()=>{model=readModel(saved);mount();draw();rememberDraft();announce();};
$('view-2d').onclick=()=>view('2d');$('view-3d').onclick=()=>view('3d');
$('reset-camera').onclick=()=>{orbit.reset();camera.position.set(0,0,2.5);camera.zoom=1;camera.updateProjectionMatrix();orbit.update();render();};
$('transparent').onclick=()=>{transparent=!transparent;$('transparent').setAttribute('aria-pressed',String(transparent));};
$('png-export').onclick=async()=>{
  $('png-export').disabled=true;
  try{
    const canvas=document.createElement('canvas');canvas.width=canvas.height=2048;const ctx=canvas.getContext('2d');
    if(!transparent){ctx.fillStyle='#16231b';ctx.fillRect(0,0,2048,2048);}
    if(mode==='2d'){
      const url=URL.createObjectURL(new Blob([writeSvg(model)],{type:'image/svg+xml'}));
      try{const img=new Image();img.src=url;await img.decode();ctx.drawImage(img,0,0,2048,2048);}finally{URL.revokeObjectURL(url);}
    }else{
      const pixelRatio=renderer.getPixelRatio();const bounds=[camera.left,camera.right,camera.top,camera.bottom];
      try{renderer.setPixelRatio(1);renderer.setSize(2048,2048,false);camera.left=camera.bottom=-.6;camera.right=camera.top=.6;camera.updateProjectionMatrix();render();ctx.drawImage($('scene'),0,0);}
      finally{[camera.left,camera.right,camera.top,camera.bottom]=bounds;renderer.setPixelRatio(pixelRatio);resize();}
    }
    const blob=await new Promise(r=>canvas.toBlob(r,'image/png'));if(!blob)throw new Error('PNGを作成できません');
    if(initial.apiBase){const data=await api('/export/png',blob,'image/png');status('PNGを書き出しました: '+data.url.split('/').at(-1));}
    download(blob,'ladyland-logo-'+mode+(transparent?'-transparent':'')+'.png');
  }catch(e){status(e.message);}finally{$('png-export').disabled=false;}
};
window.addEventListener('beforeunload',e=>{if(dirty()){e.preventDefault();e.returnValue='';}});
mount();draw();announce();
