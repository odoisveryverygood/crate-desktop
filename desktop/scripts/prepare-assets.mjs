import {cpSync,mkdirSync,existsSync} from 'node:fs';
import path from 'node:path';
const source=path.resolve(process.argv[2]||'../../outputs/CRATE-Studio-Library');
if(!existsSync(path.join(source,'oneshots.json')))throw new Error('A complete original Studio library is required');
mkdirSync('assets',{recursive:true});cpSync(source,'assets/library',{recursive:true});
console.log('Studio library prepared');
