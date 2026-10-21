// Creo: mem_1Cft9Di4PSzVCwhu9BCbA4
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,readFile,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
const api=await import('./studio-server.mjs').catch(e=>{if(e.code==='ERR_MODULE_NOT_FOUND')return {};throw e;});
test('save persists changes, rejects invalid/auth/stale writes and serializes simultaneous saves', async()=>{
  assert.equal(typeof api.createStudioServer,'function');
  const {defaults,writeSvg}=await import('./logo-model.mjs');
  const dir=await mkdtemp(join(tmpdir(),'ladyland-logo-'));
  const original=writeSvg(defaults), changed=writeSvg({...defaults,gap:0.5});
  await writeFile(join(dir,'source.svg'),original);
  const {server,token}=api.createStudioServer({assetDir:dir,webDir:dir});
  try {
    await new Promise(r=>server.listen(0,'127.0.0.1',r));
    const base='http://127.0.0.1:'+server.address().port;
    const save=(svg,revision,auth=token)=>fetch(base+'/save',{method:'POST',headers:{'Content-Type':'application/json','X-Ladyland-Token':auth},body:JSON.stringify({svg,revision})});
    const revision=api.svgRevision(original);
    assert.equal((await save(changed,revision,'wrong')).status,403);
    assert.equal((await save('<svg/>',revision)).status,400);
    assert.equal(await readFile(join(dir,'source.svg'),'utf8'),original);
    const responses=await Promise.all([save(changed,revision),save(original,revision)]);
    assert.deepEqual(responses.map(r=>r.status).sort(),[200,409]);
    assert.equal(await readFile(join(dir,'source.svg'),'utf8'),changed);
    assert.equal((await save(original,revision)).status,409);
    assert.equal((await fetch(base+'/../package.json')).status,404);
  } finally {await new Promise(r=>server.close(r));await rm(dir,{recursive:true,force:true});}
});
