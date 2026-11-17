import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import App from './App';
import { loadLanguage } from './lib/core';
import { refreshLibrary } from './lib/library';
import './theme.css';

loadLanguage()
  .catch(() => {})
  .finally(() => {
    refreshLibrary();
    createRoot(document.getElementById('root')!).render(<StrictMode><App /></StrictMode>);
  });
