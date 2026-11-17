import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import App from './App';
import { loadLanguage } from './lib/core';
import { refreshLibrary } from './lib/library';
import './theme.css';

// the macOS test build's window has its buttons over the sidebar's top
if (window.twimshelf?.platform === 'darwin') document.documentElement.classList.add('mac-titlebar');

loadLanguage()
  .catch(() => {})
  .finally(() => {
    refreshLibrary();
    createRoot(document.getElementById('root')!).render(<StrictMode><App /></StrictMode>);
  });
