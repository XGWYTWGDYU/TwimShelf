import type { ReactNode } from 'react';

export function markPattern(terms: string[]): RegExp | undefined {
  const words = terms.filter(Boolean).sort((a, b) => b.length - a.length);
  if (!words.length) return;
  return new RegExp(words.map((word) => word.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|'), 'giu');
}

export function markMatches(text: string, pattern?: RegExp): ReactNode {
  if (!pattern) return text;
  const parts: ReactNode[] = [];
  let start = 0;
  for (const match of text.matchAll(pattern)) {
    const index = match.index;
    parts.push(text.slice(start, index), <mark className="search-mark" key={index}>{match[0]}</mark>);
    start = index + match[0].length;
  }
  if (!start) return text;
  parts.push(text.slice(start));
  return parts;
}
