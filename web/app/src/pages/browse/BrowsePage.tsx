import { L } from '@twimshelf/core';
import { Page, Empty } from '../../components/ui';
import type { Route } from '../../lib/router';

export default function BrowsePage({ route }: { route: Extract<Route, { page: 'browse' }> }) {
  return <Page title={L('place.browse')}><Empty title={JSON.stringify(route)} /></Page>;
}
