// What the page may know about the desktop app (nothing more is exposed).
const { contextBridge } = require('electron');
contextBridge.exposeInMainWorld('twimshelf', { desktop: true, platform: process.platform });
