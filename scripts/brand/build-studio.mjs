import {build} from 'esbuild';
import {readFile,writeFile,mkdir,copyFile} from 'node:fs/promises';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {join} from 'node:path';
import {updateLogo} from './logo-model.mjs';
import {studioPage,svgRevision} from './studio-server.mjs';

export async function buildStudio() {
  const directory=fileURLToPath(new URL('../../output/brand/logo-generator/',import.meta.url));
  const source=await readFile(new URL('../../assets/brand/source.svg',import.meta.url),'utf8');
  if (updateLogo(source)!==source) throw new Error('source.svgの描画と設定値が一致していません');
  await mkdir(directory,{recursive:true});
  await build({entryPoints:[fileURLToPath(new URL('./studio.mjs',import.meta.url))],outfile:join(directory,'studio.js'),bundle:true,minify:true,format:'iife',target:'es2022',loader:{'.glsl':'text'},legalComments:'eof'});
  await build({entryPoints:[fileURLToPath(new URL('./studio-server.mjs',import.meta.url))],outfile:join(directory,'runtime.mjs'),bundle:true,platform:'node',format:'esm',target:'node22'});
  const template=await readFile(new URL('./studio.html',import.meta.url),'utf8');
  await writeFile(join(directory,'index.template.html'),template);
  await writeFile(join(directory,'index.html'),studioPage(template,{source,revision:svgRevision(source),apiBase:null,token:null}));
  await writeFile(join(directory,'source.svg'),source);
  await writeFile(join(directory,'start.mjs'),"import {fileURLToPath} from 'node:url';\nimport {startStudio} from './runtime.mjs';\nconst directory=fileURLToPath(new URL('./',import.meta.url));\nawait startStudio({assetDir:directory,webDir:directory});\n");
  await writeFile(join(directory,'README.txt'),'Ladyland Logo Generator\n\nこのフォルダだけで動きます。Ladylandアプリ・VP・bun installは不要です。\n\n推奨: Node.js 22以降で node start.mjs\n表示: http://127.0.0.1:12095/\n保存: このフォルダのsource.svgへ形・色・質感・照明を保存。\n\nindex.htmlには直接起動用のデータも含めていますが、file URLでの直接起動は未確認です。この場合の保存はSVGダウンロードです。\nPNG: 2048×2048 / 背景あり・透過。文字はプレビュー専用。\nSVG: 編集用の正本。3Dシェーダーの見た目はPNGで書き出してください。\n');
  await copyFile(new URL('./node_modules/three/LICENSE',import.meta.url),join(directory,'THREE-LICENSE.txt'));
  console.log('Built '+directory);
  return directory;
}
if (process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href) await buildStudio();
