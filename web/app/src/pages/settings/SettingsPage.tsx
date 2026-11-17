import { useEffect } from 'react';
import { L } from '@twimshelf/core';
import { Archive, Download, HardDrive, Info, LogOut, Puzzle, RefreshCw, Sparkles, Tags, Trash2 } from 'lucide-react';
import { Page, Row, Section } from '../../components/ui';
import { useStore } from '../../lib/hooks';
import { stats } from '../../lib/library';
import TagsPage from '../TagsPage';
import DownloadsPage from './DownloadsPage';
import TransferPage from './TransferPage';
import ImportRecordsPage from './ImportRecordsPage';
import SyncPage from './SyncPage';
import ExtensionPage from './ExtensionPage';
import AIPage from './AIPage';
import { enableAutoTagging } from './aiTagging';
import ModelHubPage from './ModelHubPage';
import { AboutPage, StoragePage, WipePage } from './MaintenancePages';
import { settings } from './settingsControls';

const pages = {
  downloads: DownloadsPage,
  'import-backup': TransferPage,
  tags: () => <TagsPage back={() => settings()} />,
  ai: AIPage,
  sync: SyncPage,
  extension: ExtensionPage,
  storage: StoragePage,
  about: AboutPage,
  'import-records': ImportRecordsPage,
  'model-hub': ModelHubPage,
  'clear-all-data': WipePage,
};

const groups = [
  { title: 'settings.section.content', pages: [
    { sub: 'downloads', label: 'common.downloadPosts', icon: Download },
    { sub: 'import-backup', label: 'common.importAndBackup', icon: Archive },
    { sub: 'tags', label: 'common.tags', icon: Tags },
  ] },
  { title: 'settings.section.smart', pages: [
    { sub: 'ai', label: 'models.tagging', icon: Sparkles },
    { sub: 'sync', label: 'common.lanSync', icon: RefreshCw },
    { sub: 'extension', label: 'ext.title', icon: Puzzle },
  ] },
  { title: 'sidebar.other', pages: [
    { sub: 'storage', label: 'storage.title', icon: HardDrive },
    { sub: 'about', label: 'settings.about', icon: Info },
  ] },
];

export default function SettingsPage({ sub }: { sub?: string }) {
  const counts = useStore(stats);
  useEffect(enableAutoTagging, []);
  if (sub && Object.hasOwn(pages, sub)) {
    const Screen = pages[sub as keyof typeof pages];
    return <Screen />;
  }
  return <Page title={L('place.settings')}>
    {counts && <Section title={L('common.library')}><div className="control-stats">
      {([
        ['common.posts', counts.posts], ['search.kw.photo.word', counts.photos],
        ['place.videos', counts.videos], ['common.tags', counts.tags],
      ] as const).map(([key, number]) => <div key={key}><strong>{number.toLocaleString()}</strong><small>{L(key)}</small></div>)}
    </div></Section>}
    {groups.map((group) => <Section key={group.title} title={L(group.title)}>
      {group.pages.map(({ sub, label, icon: Icon }) => <Row key={sub} icon={<Icon size={18} />}
        title={L(label)} onClick={() => settings(sub)} />)}
    </Section>)}
    {!window.twimshelf && <Section footer={L('settings.signOut.footer')}>
      <Row icon={<LogOut size={18} />} title={L('settings.signOut')} onClick={() => { location.href = '/logout'; }} />
    </Section>}
    <Section footer={L('settings.wipe.footer')}>
      <Row icon={<Trash2 size={18} />} danger title={L('settings.wipe.button')} onClick={() => settings('clear-all-data')} />
    </Section>
  </Page>;
}
