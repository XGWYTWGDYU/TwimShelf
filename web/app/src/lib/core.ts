// The app's one Core: the page's own server (the web), or the local one the Electron app gives.
import { Core, httpTransport, setStrings, pickLanguage, type Strings } from '@twimshelf/core';
import en from '@twimshelf/core/src/generated/strings/en.json';

/** An item of a system menu (Electron): what the page sends to the desktop app. */
export type NativeMenuItem = 'separator' | { id?: string; label: string; enabled?: boolean; checked?: boolean; accel?: string; role?: string; children?: NativeMenuItem[] };

declare global {
  interface Window {
    /** Set by the Electron app's preload. Its window is served by its own local server (signed
     *  in by a cookie the app sets), so the page talks to it exactly like the web page does. */
    twimshelf?: {
      desktop: true;
      platform: string;
      popupMenu?: (items: NativeMenuItem[], x: number, y: number) => Promise<string | null>;
      setAppMenu?: (menus: { label: string; role?: string; items: (NativeMenuItem | 'separator')[] }[]) => void;
      onAppMenu?: (f: (id: string) => void) => () => void;
      setViewerMode?: (on: boolean) => void;
      toggleFullScreen?: () => void;
      showItemInFolder?: (path: string) => void;
      getMascotEnabled?: () => Promise<boolean>;
      setMascotEnabled?: (enabled: boolean) => Promise<void>;
    };
  }
}

/** The desktop (Electron) app rather than a browser. */
export const desktop = window.twimshelf?.desktop === true;

export const core = new Core(
  httpTransport({
    onSignedOut: () => {
      if (!desktop) location.href = `/login?next=${encodeURIComponent(location.pathname + location.hash)}`;
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
