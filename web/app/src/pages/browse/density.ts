import { store } from '@twimshelf/core';

export const cardDensities = ['fewer', 'medium', 'more'] as const;
export type CardDensity = typeof cardDensities[number];

const key = 'feed.density.landscape';
function readDensity(): CardDensity {
  try {
    const saved = localStorage.getItem(key);
    return cardDensities.find((density) => saved === density) ?? 'medium';
  } catch {
    return 'medium';
  }
}

export const cardDensity = store(readDensity());

export function setCardDensity(density: CardDensity): void {
  cardDensity.set(density);
  try { localStorage.setItem(key, density); } catch { /* unavailable storage */ }
}

export function cardColumns(width: number, density: CardDensity): number {
  const perCard = { fewer: 405, medium: 300, more: 216 }[density];
  return Math.max(1, Math.min(density === 'more' ? 8 : 6, Math.floor(width / perCard)));
}
