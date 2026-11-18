// "Show Post in Browse" from a grid: 浏览 shows that media's post in the middle, turned to that
// media and briefly marked (MacFeedViewController.reveal); a search that hides it is cleared first.
import { store, type FeedItem } from '@twimshelf/core';
import { go } from '../../lib/router';

export const revealRequest = store<{ item: FeedItem; at: number } | null>(null);

export function revealInBrowse(item: FeedItem): void {
  revealRequest.set({ item, at: Date.now() });
  go({ page: 'browse' });
}
