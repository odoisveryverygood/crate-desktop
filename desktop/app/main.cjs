const {app,BrowserWindow,ipcMain,protocol,net,dialog,safeStorage}=require('electron');
const fs=require('node:fs/promises'),path=require('node:path'),crypto=require('node:crypto');
const {pathToFileURL}=require('node:url');
const backend='https://crate-desktop-api.pocketvet-ai.workers.dev';
app.setPath('userData',path.join(app.getPath('appData'),'CRATE Desktop'));
const verify=process.argv.includes('--verify'),hostedVerify=verify&&process.argv.includes('--hosted');
if(verify)app.setPath('userData',path.join(require('node:os').tmpdir(),'crate-verify-'+crypto.randomUUID()));
protocol.registerSchemesAsPrivileged([{scheme:'crate',privileges:{standard:true,secure:true,supportFetchAPI:true,stream:true,corsEnabled:true}}]);
let win,config,sessionPromise,memoryToken,memoryExpiry=0;
const store=()=>app.getPath('userData');
const lib=()=>app.isPackaged?path.join(process.resourcesPath,'StudioLibrary'):path.join(__dirname,'../assets/library');
async function readJSON(p,fallback){try{return JSON.parse(await fs.readFile(p,'utf8'));}catch{return fallback;}}
async function persist(){await fs.mkdir(store(),{recursive:true});const p=path.join(store(),'settings.json');await fs.writeFile(p+'.tmp',JSON.stringify(config));await fs.rename(p+'.tmp',p);}
async function token(){
 if(memoryToken&&memoryExpiry>Date.now()+60000)return memoryToken;
 if(config.session&&config.expires>Date.now()+60000){try{return safeStorage.decryptString(Buffer.from(config.session,'base64'));}catch{}}
 if(sessionPromise)return sessionPromise;
 sessionPromise=(async()=>{
  const r=await fetch(backend+'/api/session',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({installation_id:config.installation}),signal:AbortSignal.timeout(8000)});
  if(!r.ok)throw new Error('CRATE AI could not connect. Try again shortly.');const d=await r.json();
  if(typeof d.token!=='string'||d.token.length>1000)throw new Error('Invalid AI session');
  memoryToken=d.token;memoryExpiry=Date.now()+d.expires_in*1000;
  if(safeStorage.isEncryptionAvailable()&&(process.platform!=='linux'||safeStorage.getSelectedStorageBackend()!=='basic_text')){config.session=safeStorage.encryptString(d.token).toString('base64');config.expires=Date.now()+d.expires_in*1000;await persist();}
  return d.token;
 })();try{return await sessionPromise;}finally{sessionPromise=null;}
}
const validSender=e=>e.senderFrame?.url?.startsWith('crate://app/');
function handle(name,fn){ipcMain.handle(name,async(e,...args)=>{if(!validSender(e))throw new Error('Untrusted sender');return fn(...args);});}
function contained(root,relative){const p=path.resolve(root,relative);if(p!==root&&!p.startsWith(root+path.sep))throw new Error('Invalid asset path');return p;}
app.whenReady().then(async()=>{
 await fs.mkdir(store(),{recursive:true});config=await readJSON(path.join(store(),'settings.json'),{installation:crypto.randomUUID(),aiAllowed:hostedVerify});
 protocol.handle('crate',async req=>{
  const u=new URL(req.url);let root;
  if(u.hostname==='app')root=path.resolve(__dirname);
  else if(u.hostname==='library')root=path.resolve(lib());
  else if(u.hostname==='imports')root=path.resolve(store(),'imports');
  else return new Response('',{status:404});
  try{const file=contained(root,decodeURIComponent(u.pathname.slice(1))),r=await net.fetch(pathToFileURL(file).href);const types={'.html':'text/html','.mjs':'text/javascript','.cjs':'text/javascript','.css':'text/css','.json':'application/json','.wav':'audio/wav'};return new Response(r.body,{status:r.status,headers:{'content-type':types[path.extname(file)]||r.headers.get('content-type')||'application/octet-stream','access-control-allow-origin':'crate://app','x-content-type-options':'nosniff'}});}catch{return new Response('',{status:404});}
 });
 handle('config',()=>({aiAllowed:config.aiAllowed,verify,hostedVerify,platform:process.platform,version:app.getVersion()}));
 handle('consent',async value=>{config.aiAllowed=value===true;await persist();return config.aiAllowed;});
 handle('ai',async(kind,payload)=>{
  if(!config.aiAllowed||(verify&&!hostedVerify))throw new Error('Enable AI help first');
  if(!['jev','openai'].includes(kind)||!payload||JSON.stringify(payload).length>39000)throw new Error('Invalid AI request');
  const send=async()=>fetch(backend+'/api/ai/'+kind,{method:'POST',headers:{'content-type':'application/json','x-crate-token':await token()},body:JSON.stringify(payload),signal:AbortSignal.timeout(kind==='jev'?5500:16000)});
  let r=await send();if(r.status===401){config.session=null;config.expires=0;memoryToken=null;memoryExpiry=0;r=await send();}
  if(r.status===429)throw new Error('CRATE AI limit reached. Your local sampler remains ready.');
  if(!r.ok)throw new Error('AI unavailable. Kept the instant version.');return r.json();
 });
 handle('save',async project=>{
  if(!project||JSON.stringify(project).length>2000000)throw new Error('Project too large');
  const id=/^[a-f0-9-]{36}$/i.test(project.id||'')?project.id:crypto.randomUUID();project.id=id;
  const folder=path.join(store(),'projects');await fs.mkdir(folder,{recursive:true});await fs.writeFile(path.join(folder,id+'.json.tmp'),JSON.stringify(project));await fs.rename(path.join(folder,id+'.json.tmp'),path.join(folder,id+'.json'));config.lastProject=id;await persist();return id;
 });
 handle('projects',async()=>{const folder=path.join(store(),'projects');let files=[];try{files=await fs.readdir(folder);}catch{}return(await Promise.all(files.filter(f=>/^[a-f0-9-]{36}\.json$/i.test(f)).map(f=>readJSON(path.join(folder,f),null)))).filter(Boolean).map(p=>({id:p.id,name:p.name,bpm:p.bpm}));});
 handle('load',async id=>{id=id||config.lastProject;if(!/^[a-f0-9-]{36}$/i.test(id||''))return null;return readJSON(path.join(store(),'projects',id+'.json'),null);});
 handle('import-audio',async()=>{const r=await dialog.showOpenDialog(win,{properties:['openFile'],filters:[{name:'Audio',extensions:['wav','mp3','aif','aiff','m4a','ogg','flac']}]});if(r.canceled)return null;const file=r.filePaths[0],stat=await fs.stat(file);if(stat.size>200*1024*1024)throw new Error('Use an audio file under 200 MB');const name=crypto.randomUUID()+path.extname(file).toLowerCase();await fs.mkdir(path.join(store(),'imports'),{recursive:true});await fs.copyFile(file,path.join(store(),'imports',name));return {file:name,name:path.basename(file)};});
 handle('record-audio',async bytes=>{if(!(bytes instanceof Uint8Array)||bytes.length>100*1024*1024)throw new Error('Recording too large');const name=crypto.randomUUID()+'.wav';await fs.mkdir(path.join(store(),'imports'),{recursive:true});await fs.writeFile(path.join(store(),'imports',name),bytes);return {file:name,name:'TAKE '+new Date().toLocaleTimeString()};});
 handle('export-audio',async bytes=>{if(!(bytes instanceof Uint8Array)||bytes.length>200*1024*1024)throw new Error('Invalid export');const r=await dialog.showSaveDialog(win,{defaultPath:'CRATE-Beat.wav',filters:[{name:'WAV audio',extensions:['wav']}]});if(r.canceled)return false;await fs.writeFile(r.filePath,bytes);return true;});
 handle('verify-complete',async report=>{if(!verify)throw new Error('Verification is disabled');const output=process.env.CRATE_VERIFY_OUTPUT||path.join(store(),'verification.json');await fs.writeFile(output,JSON.stringify(report,null,2));console.log('CRATE_DESKTOP_CHECK '+Object.values(report.checks).filter(Boolean).length+'/'+Object.keys(report.checks).length);app.exit(report.passed?0:1);});
 win=new BrowserWindow({width:1240,height:800,minWidth:960,minHeight:640,show:!verify,title:'CRATE',backgroundColor:'#111111',webPreferences:{preload:path.join(__dirname,'preload.cjs'),contextIsolation:true,sandbox:true,nodeIntegration:false}});
 win.webContents.setWindowOpenHandler(()=>({action:'deny'}));win.webContents.on('will-navigate',(e,url)=>{if(!url.startsWith('crate://app/'))e.preventDefault();});
 if(verify){win.webContents.on('console-message',(event,...args)=>console.log('RENDERER',event.message||args[1]||args.join(' ')));setTimeout(()=>{console.error('Verification timed out');app.exit(1);},60000).unref();}
 await win.loadURL('crate://app/index.html');
});
app.on('window-all-closed',()=>app.quit());
