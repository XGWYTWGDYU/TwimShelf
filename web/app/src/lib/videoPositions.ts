// Where each video is: a card's video goes on in the viewer from its frame, and the card goes on
// from where the viewer left it (no jump back to the start), as in the apps.
import { store } from '@twimshelf/core';

const positions = new Map<string, number>();
/** Bumped when the viewer hands a video back: cards pick up their position. */
export const handedBack = store<{ id: string; at: number } | null>(null);

export function savePosition(id: string, seconds: number): void { positions.set(id, seconds); }
export function position(id: string): number { return positions.get(id) ?? 0; }
export function handBack(id: string, seconds: number): void {
  positions.set(id, seconds);
  handedBack.set({ id, at: seconds });
}
