// The app's one Core: the page's own server (the web), or the local one the Electron app gives.
import { Core, httpTransport, setStrings, pickLanguage, type Strings } from '@twimshelf/core';
import en from '@twimshelf/core/src/generated/strings/en.json';

declare global {
  interface Window {
    /** Set by the Electron app's preload: its local server and token. */
    twimshelf?: { base: string; token: string; platform: string; openExternal(url: string): void };
  }
}

const desktop = window.twimshelf;

export const core = new Core(
  httpTransport({
    base: desktop?.base ?? '',
    headers: desktop ? { authorization: `Bearer ${desktop.token}` } : undefined,
    onSignedOut: () => {
      if (!desktop) location.href = `/login?next=${encodeURIComponent(location.pathname)}`;
    },
  }),
);

const languages: Record<string, () => Promise<{ default: Strings }>> = {
  'zh-Hans': () => import('@twimshelf/core/src/generated/strings/zh-Hans.json'),
  'zh-Hant': () => import('@twimshelf/core/src/generated/strings/zh-Hant.json'),
  ja: () => import('@twimshelf/core/src/generated/strings/ja.json'),
};

export let language = 'en';

/** Loads the UI strings for the browser's language and tells the core. */
export async function loadLanguage(): Promise<void> {
  language = pickLanguage(['en', ...Object.keys(languages)], navigator.languages);
  const table = language === 'en' ? en : (await languages[language]()).default;
  setStrings(language, table as Strings, en as Strings);
  document.documentElement.lang = language;
  await core.b.tl_set_language(language);
}
