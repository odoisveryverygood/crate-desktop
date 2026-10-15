const {contextBridge,ipcRenderer}=require('electron');
contextBridge.exposeInMainWorld('crate',{
 config:()=>ipcRenderer.invoke('config'),
 ai:(kind,payload)=>ipcRenderer.invoke('ai',kind,payload),
 save:project=>ipcRenderer.invoke('save',project),
 projects:()=>ipcRenderer.invoke('projects'),
 load:id=>ipcRenderer.invoke('load',id),
 importAudio:()=>ipcRenderer.invoke('import-audio'),
 recordAudio:bytes=>ipcRenderer.invoke('record-audio',bytes),
 exportAudio:bytes=>ipcRenderer.invoke('export-audio',bytes),
 consent:value=>ipcRenderer.invoke('consent',value),
 verifyComplete:report=>ipcRenderer.invoke('verify-complete',report)
});
