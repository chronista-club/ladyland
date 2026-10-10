import {createServer} from 'node:http';
import {readFile, writeFile, rename, mkdir} from 'node:fs/promises';
import {join} from 'node:path';
import {createHash, randomBytes} from 'node:crypto';
import {updateLogo} from './logo-model.mjs';

export const svgRevision = svg => createHash('sha256').update(svg).digest('hex');
export function studioPage(template, data) {
  return template.replace('__STUDIO_DATA__',JSON.stringify(data).replace(/</g,'\\u003c'));
}

async function readBody(request,limit) {
  const chunks=[]; let size=0;
  for await (const chunk of request) {
    size+=chunk.length;
    if (size>limit) throw new Error('データが大きすぎます');
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

// このサーバーが扱うファイルは正本SVGと生成物のみ。任意パスは受け取らない。
export function createStudioServer({assetDir,webDir}) {
  const token=randomBytes(24).toString('hex');
  const sourcePath=join(assetDir,'source.svg');
  let saveQueue=Promise.resolve();
  const server=createServer(async(request,response)=>{
    const base='http://127.0.0.1:'+server.address().port;
    const route=new URL(request.url,base).pathname;
    const origin=request.headers.origin;
    const allowedOrigin=!origin||origin===base||origin==='null';
    response.setHeader('Cache-Control','no-store');
    response.setHeader('X-Content-Type-Options','nosniff');
    if (origin&&allowedOrigin) {
      response.setHeader('Access-Control-Allow-Origin',origin);
      response.setHeader('Access-Control-Allow-Headers','Content-Type, X-LADYLAND-Token');
      response.setHeader('Access-Control-Allow-Methods','GET, POST, OPTIONS');
    }
    const json=(code,data)=>{response.writeHead(code,{'Content-Type':'application/json; charset=utf-8'});response.end(JSON.stringify(data));};
    try {
      if (request.method==='OPTIONS') {response.writeHead(allowedOrigin?204:403);response.end();return;}
      if (request.method==='POST') {
        if (!allowedOrigin||request.headers['x-ladyland-token']!==token) {request.resume();json(403,{error:'保存元を確認できません。ページを開き直してください。'});return;}
        if (route==='/save') {
          const body=JSON.parse((await readBody(request,1024*1024)).toString('utf8'));
          const svg=updateLogo(body.svg);
          const save=async()=>{
            const before=await readFile(sourcePath,'utf8');
            if (svgRevision(before)!==body.revision) return json(409,{error:'正本が別の場所で更新されています。編集用SVGを書き出してから、ページを開き直してください。'});
            const temporary=sourcePath+'.'+randomBytes(5).toString('hex')+'.tmp';
            await writeFile(temporary,svg);
            await rename(temporary,sourcePath);
            json(200,{revision:svgRevision(svg)});
          };
          saveQueue=saveQueue.then(save,save);
          await saveQueue;
          return;
        }
        if (route==='/export/png') {
          const png=await readBody(request,24*1024*1024);
          if (png.length<24||png.subarray(0,8).toString('hex')!=='89504e470d0a1a0a'||png.readUInt32BE(16)>8192||png.readUInt32BE(20)>8192) throw new Error('PNGの形式が不正です');
          const filename='ladyland-logo-'+Date.now()+'-'+randomBytes(3).toString('hex')+'.png';
          await mkdir(join(webDir,'exports'),{recursive:true});
          await writeFile(join(webDir,'exports',filename),png);
          json(201,{url:'/exports/'+filename});
          return;
        }
      }
      if (request.method==='GET'&&(route==='/'||route==='/index.html')) {
        await saveQueue;
        const source=await readFile(sourcePath,'utf8');
        const template=await readFile(join(webDir,'index.template.html'),'utf8');
        response.writeHead(200,{'Content-Type':'text/html; charset=utf-8'});
        response.end(studioPage(template,{source,revision:svgRevision(source),apiBase:base,token}));
        return;
      }
      if (request.method==='GET'&&route==='/studio.js') {
        response.writeHead(200,{'Content-Type':'text/javascript; charset=utf-8'});
        response.end(await readFile(join(webDir,'studio.js')));return;
      }
      if (request.method==='GET'&&route==='/source.svg') {
        await saveQueue;
        response.writeHead(200,{'Content-Type':'image/svg+xml'});
        response.end(await readFile(sourcePath));return;
      }
      if (request.method==='GET'&&/^\/exports\/ladyland-logo-\d+-[a-f0-9]+\.png$/.test(route)) {
        const png=await readFile(join(webDir,route.slice(1)));
        response.writeHead(200,{'Content-Type':'image/png'});response.end(png);return;
      }
      json(404,{error:'見つかりません'});
    } catch(error) {
      if (!response.headersSent) json(400,{error:error.message});
      else response.end();
    }
  });
  return {server,token};
}

export async function startStudio(options) {
  const port=Number(process.env.LADYLAND_LOGO_PORT||12095);
  if (!Number.isInteger(port)||port<1024||port>65535) throw new Error('LADYLAND_LOGO_PORTが不正です');
  const {server}=createStudioServer(options);
  await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(port,'127.0.0.1',resolve);});
  console.log('LADYLAND Logo Generator: http://127.0.0.1:'+port+'/');
  return server;
}
