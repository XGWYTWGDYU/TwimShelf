// electron-builder's settings for the desktop app (build.sh electron-linux / electron-macos).
// build.sh passes the server binary (TL_SERVER_BIN) and the built React app (TL_WEB_DIST);
// scripts/apply.py writes product.json (name, id, version, build number) and icon.png from
// config.yaml first.
const path = require('node:path');
const product = require('./product.json');

module.exports = {
  appId: product.appId,
  productName: product.name,
  directories: { output: process.env.TL_ELECTRON_OUT || path.join(__dirname, 'release') },
  files: ['main.cjs', 'preload.cjs', 'product.json', 'icon.png'],
  extraMetadata: { version: product.version },
  buildVersion: product.buildNumber,
  extraResources: [
    { from: process.env.TL_SERVER_BIN, to: 'server/twimshelf-server' },
    { from: process.env.TL_WEB_DIST, to: 'web' },
  ],
  asar: true,
  // the Electron this repository installed (no second download on this computer)
  electronDist: process.platform === 'darwin' ? path.join(__dirname, '..', 'node_modules', 'electron', 'dist') : undefined,
  linux: {
    target: ['AppImage'],
    // the program's file name on Linux (the Mac's app is named after productName)
    executableName: 'twimshelf',
    category: 'Graphics',
    icon: path.join(__dirname, 'icon.png'),
    artifactName: 'TwimShelf-${version}-linux-${arch}.${ext}',
  },
  // the macOS build is for testing the Linux app's UI on a Mac only: unsigned, never published
  mac: {
    target: ['dir'],
    identity: null,
    icon: path.join(__dirname, 'icon.png'),
    artifactName: 'TwimShelf-Electron-${version}-macOS-${arch}.${ext}',
  },
};
