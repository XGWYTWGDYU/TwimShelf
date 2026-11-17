// Placeholder: written in a later step (see web/README.md, "Who does what").
import { L } from '@twimshelf/core';
import { Page, Empty } from '../../components/ui';

export default function SettingsPage({ sub }: { sub?: string }) {
  return <Page title={L('place.settings')}><Empty title={sub ?? 'Not written yet'} /></Page>;
}
