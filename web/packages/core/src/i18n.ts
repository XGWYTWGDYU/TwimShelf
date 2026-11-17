// UI strings: generated from Apple/Resources/Localizable.xcstrings by scripts/to_web.py into
// generated/strings/<language>.json (never edit those). `L(key, …args)` fills %@ / %lld / %1$@;
// a plural entry ({one, other, …}) is chosen by the first numeric argument.
export type Strings = Record<string, string | Record<string, string>>;

let table: Strings = {};
let fallback: Strings = {};
let language = 'en';

export function setStrings(lang: string, strings: Strings, base: Strings = {}): void {
  language = lang;
  table = strings;
  fallback = base;
}

export function L(key: string, ...args: Array<string | number>): string {
  const entry = table[key] ?? fallback[key] ?? key;
  let s: string;
  if (typeof entry === 'string') s = entry;
  else {
    const n = args.find((a) => typeof a === 'number') as number | undefined;
    const form = n === undefined ? 'other' : new Intl.PluralRules(language).select(n);
    s = entry[form] ?? entry.other ?? Object.values(entry)[0] ?? key;
  }
  let next = 0;
  s = s.replace(/%(?:(\d+)\$)?(?:@|lld|ld|d|f|\.\d+f)/g, (_m, pos: string | undefined) => {
    const i = pos ? Number(pos) - 1 : next++;
    return args[i] === undefined ? '' : String(args[i]);
  });
  return s.replace(/%%/g, '%');
}

/** The best of `available` for the browser's languages (e.g. zh-Hans for zh-CN). */
export function pickLanguage(available: string[], wanted: readonly string[]): string {
  const norm = (t: string) => t.toLowerCase();
  for (const w of wanted.map(norm)) {
    const exact = available.find((a) => norm(a) === w);
    if (exact) return exact;
    if (w.startsWith('zh')) {
      const hant = /-(tw|hk|mo|hant)/.test(w);
      const zh = available.find((a) => norm(a) === (hant ? 'zh-hant' : 'zh-hans'));
      if (zh) return zh;
    }
    const lang = available.find((a) => norm(a).split('-')[0] === w.split('-')[0]);
    if (lang) return lang;
  }
  return available.includes('en') ? 'en' : available[0];
}
