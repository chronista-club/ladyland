import {fileURLToPath} from 'node:url';
import {buildStudio} from './build-studio.mjs';
import {startStudio} from './studio-server.mjs';
const webDir=await buildStudio();
await startStudio({assetDir:fileURLToPath(new URL('../../assets/brand/',import.meta.url)),webDir});
