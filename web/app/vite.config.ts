import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// `npm run dev`: the page from Vite, everything else from a TwimShelf server (TL_SERVER, default
// http://localhost:8080), so the app runs against a real library while it is being written.
const server = process.env.TL_SERVER ?? 'http://localhost:8080';
const proxied = ['/api', '/f', '/login', '/logout', '/ext', '/gfonts'];

export default defineConfig({
  plugins: [react()],
  base: './',
  // the CSS is not minified: Lightning CSS wrote `backdrop-filter: blur(20px)saturate(1.6)`, with
  // no space between the functions and only the prefixed name, which Chromium rejects, so no
  // glass was ever blurred (the server compresses what it sends anyway)
  build: { outDir: 'dist', sourcemap: false, cssMinify: false },
  server: { proxy: Object.fromEntries(proxied.map((p) => [p, { target: server, changeOrigin: false }])) },
});
