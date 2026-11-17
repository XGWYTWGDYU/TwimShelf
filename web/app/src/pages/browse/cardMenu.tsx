// The card's context menu (as the apps' card_menu.dart) and the selection's.
import { BadgeCheck, CircleUserRound, CloudDownload, ExternalLink, Filter, FolderInput, FolderMinus, FolderPlus, Layers, Pencil, Search, Sparkles, Tag, TagsIcon, Trash2, X } from 'lucide-react';
import { L, KEYWORDS, keywordWord, type FeedItem } from '@twimshelf/core';
import type { MenuEntry } from '../../components/Menu';
import { askText, pickFolder, pickTag } from '../../components/pickers';
import { toast } from '../../components/toast';
import { addTag, isAI, isUser, removeTag, runAction } from '../../lib/actions';
import { core } from '../../lib/core';
import { libraryChanged } from '../../lib/library';

export interface CardMenuHost {
  /** Replaces the search with these words. */
  search: (q: string) => void;
  /** Adds a word to the search. */
  addTerm: (word: string) => void;
}

const kw = (id: string) => keywordWord(KEYWORDS.find((k) => k.id === id)!);
const z = 14;

async function toFolder(o: { media?: string[]; posts?: string[] }) {
  const folder = await pickFolder();
  if (folder) await runAction('folder_add', { ...o, folder }, () => L('tags.toFolder.done', folder));
}

async function tagMany(ids: string[], title: string) {
  const label = await pickTag(title);
  if (!label) return;
  for (const id of ids) await addTag(id, label);
  libraryChanged();
}

export async function cardMenu(item: FeedItem, post: FeedItem[], host: CardMenuHost): Promise<MenuEntry[]> {
  const loose = item.post_id.startsWith('loose:');
  const authorKey = item.screen_name ?? item.author_name;
  const authorDisplay = item.screen_name ? `@${item.screen_name}` : item.author_name ?? L('common.unknownAuthor');
  const pending = item.tags.filter((t) => isAI(t.origin) && !isUser(t.origin));
  let inFolders: string[] = [];
  try { inFolders = await core.read<string[]>(core.b.tl_media_folders(item.media_id)); } catch { /* none */ }

  const deleteTag = async (label: string, origin: number) => {
    await removeTag(item, label);
    libraryChanged();
    toast(L('tag.deleted', label), {
      label: L('common.undo'),
      run: async () => {
        if (isAI(origin)) await addTag(item, label, true);
        if (isUser(origin)) await addTag(item, label);
        libraryChanged();
      },
    });
  };

  return [
    ...(!loose && authorKey ? [{ label: L('card.menu.onlyAuthor', authorDisplay), icon: <CircleUserRound size={z} />, run: () => host.search(`${authorKey} ${kw('author')}`) }] : []),
    ...(!loose && item.screen_name ? [{ label: L('card.menu.openProfile', item.screen_name), icon: <ExternalLink size={z} />, run: () => window.open(`https://x.com/${item.screen_name}`, '_blank', 'noopener') }] : []),
    'separator',
    { label: L('card.menu.tagMedia'), icon: <Tag size={z} />, run: () => void tagMany([item.media_id], L('card.menu.tagMedia')) },
    ...(!loose && post.length > 1 ? [{ label: L('card.menu.tagPost'), icon: <Layers size={z} />, run: () => void tagMany(post.map((m) => m.media_id), L('card.menu.tagPost')) }] : []),
    ...(pending.length ? [{ label: L('card.menu.approveAll'), icon: <BadgeCheck size={z} />, run: async () => { for (const t of pending) await addTag(item, t.label); libraryChanged(); } }] : []),
    'separator',
    ...item.tags.map((t) => ({
      label: t.label,
      icon: isAI(t.origin) ? (isUser(t.origin) ? <BadgeCheck size={z} /> : <Sparkles size={z} />) : <Tag size={z} />,
      children: [
        { label: L('card.menu.onlyTag'), icon: <Filter size={z} />, run: () => host.search(`${t.label} ${kw('tags')}`) },
        { label: L('card.menu.searchTag'), icon: <Search size={z} />, run: () => host.addTerm(t.label) },
        ...(isAI(t.origin) && !isUser(t.origin) ? [{ label: L('card.menu.approve'), icon: <BadgeCheck size={z} />, run: async () => { await addTag(item, t.label); libraryChanged(); } }] : []),
        { label: L('card.menu.renameTag'), icon: <Pencil size={z} />, run: async () => {
          const to = await askText(L('card.menu.renameTag'), t.label);
          if (to && to !== t.label) { await core.read(core.b.tl_rename_tag(t.label, to)); libraryChanged(); }
        } },
        'separator' as const,
        { label: L('card.menu.deleteTag'), icon: <X size={z} />, danger: true, run: () => void deleteTag(t.label, t.origin) },
      ],
    })),
    'separator',
    { label: L('common.addToFolder'), icon: <FolderPlus size={z} />, run: () => void toFolder({ media: [item.media_id] }) },
    ...(!loose ? [{ label: L('card.menu.postToFolder'), icon: <FolderInput size={z} />, run: () => void toFolder({ posts: [item.post_id] }) }] : []),
    ...(inFolders.length ? [{
      label: L('common.removeFromFolder'), icon: <FolderMinus size={z} />,
      children: inFolders.map((f) => ({
        label: f, icon: <FolderMinus size={z} />,
        children: [
          { label: L('card.menu.removeMedia'), run: () => void runAction('folder_remove', { media: [item.media_id], folder: f }, () => L('common.removeFromFolder')) },
          ...(!loose ? [{ label: L('card.menu.removePost'), run: () => void runAction('folder_remove', { posts: [item.post_id], folder: f }, () => L('common.removeFromFolder')) }] : []),
        ],
      })),
    }] : []),
    'separator',
    ...(item.url || /^[0-9]+$/.test(item.post_id) ? [{
      label: item.bad ? L('card.menu.redownloadBad') : L('card.menu.redownload'), icon: <CloudDownload size={z} />,
      run: async () => {
        toast(L('common.redownloading'));
        try { await core.read(core.b.tl_repair(item.media_id)); libraryChanged(); toast(L('repair.fixed')); }
        catch (e) { toast(`${L('repair.failed')}: ${L(String((e as Error).message))}`); }
      },
    }] : []),
    'separator',
    { label: L('card.menu.deleteMedia'), icon: <Trash2 size={z} />, danger: true, run: () => void runAction('trash', { media: [item.media_id] }, (n) => L('trash.moved', n)) },
    ...(!loose ? [{ label: L('card.menu.deletePost'), icon: <Trash2 size={z} />, danger: true, run: () => void runAction('trash', { posts: [item.post_id] }, (n) => L('trash.moved', n)) }] : []),
  ];
}

/** The menu for several selected posts. */
export function selectionMenu(media: string[], posts: string[], clear: () => void): MenuEntry[] {
  return [
    { label: L('card.menu.tagMedia'), icon: <TagsIcon size={z} />, run: () => void tagMany(media, L('card.menu.tagMedia')) },
    { label: L('common.addToFolder'), icon: <FolderPlus size={z} />, run: () => void toFolder({ posts }) },
    'separator',
    { label: L('card.menu.deletePost'), icon: <Trash2 size={z} />, danger: true, run: async () => { if (await runAction('trash', { posts }, (n) => L('trash.moved', n))) clear(); } },
  ];
}

export { tagMany, toFolder };
