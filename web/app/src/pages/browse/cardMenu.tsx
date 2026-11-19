// The card's context menu (matching Apple/macOS/MacFeed.swift) and the selection's.
import {
  BadgeCheck, CircleUserRound, CloudDownload, ExternalLink, Filter, FolderInput, FolderMinus,
  FolderPlus, Info, Layers, Pencil, Search, Sparkles, Tag, TagsIcon, Trash2, X,
} from 'lucide-react';
import { L, KEYWORDS, keywordWord, quoteSearchWord, type FeedItem, type MediaRef, type TagView } from '@twimshelf/core';
import type { MenuEntry } from '../../components/Menu';
import { alertMessage, openTagPicker, pickFolder, prompt } from '../../components/pickers';
import { toast } from '../../components/toast';
import { addTag, isAI, isUser, removeTag, runAction } from '../../lib/actions';
import { core } from '../../lib/core';
import { libraryChanged } from '../../lib/library';
import { activeTagger, allTaggers, retagMedia } from '../settings/aiTagging';

export interface CardMenuHost {
  /** Replaces the search with these words. */
  search: (q: string) => void;
  /** Adds a word (or space-separated words) to the search. */
  addTerm: (word: string) => void;
}

const kw = (id: string) => keywordWord(KEYWORDS.find((k) => k.id === id)!);
const z = 14;

async function toFolder(o: { media?: string[]; posts?: string[] }) {
  const folder = await pickFolder();
  if (folder) await runAction('folder_add', { ...o, folder }, () => L('tags.toFolder.done', folder));
}

async function tagMany(ids: string[], title: string) {
  await openTagPicker({ mediaIds: ids, title });
}

function toMediaRef(item: FeedItem): MediaRef {
  return {
    media_id: item.media_id,
    kind: item.kind,
    path: item.path,
    text: item.text ?? null,
  };
}

function showTagSources(item: FeedItem) {
  const lines = item.tags.map((t) => {
    const src = isUser(t.origin) && isAI(t.origin)
      ? L('tag.source.both')
      : isAI(t.origin) ? 'AI' : L('tag.source.me');
    return t.models.length > 0
      ? L('tag.sourceLineModels', t.label, src, t.models.join(L('list.separator')))
      : L('tag.sourceLine', t.label, src);
  });
  lines.push('', L('tag.sources.legend'));
  void alertMessage(L('tag.sources.title'), lines.join('\n'));
}

export async function cardMenu(item: FeedItem, post: FeedItem[], host: CardMenuHost): Promise<MenuEntry[]> {
  const loose = item.post_id.startsWith('loose:');
  const authorKey = item.screen_name ?? item.author_name;
  const authorDisplay = item.screen_name ? `@${item.screen_name}` : item.author_name ?? L('common.unknownAuthor');
  const pending = item.tags.filter((t) => isAI(t.origin) && !isUser(t.origin));
  const [inFolders, taggers] = await Promise.all([
    core.read<string[]>(core.b.tl_media_folders(item.media_id)).catch(() => [] as string[]),
    allTaggers().catch(() => []),
  ]);
  const currentTagger = activeTagger.get();
  const ref = toMediaRef(item);

  return [
    ...(!loose && authorKey ? [{
      label: L('card.menu.onlyAuthor', authorDisplay),
      icon: <CircleUserRound size={z} />,
      run: () => { host.addTerm(quoteSearchWord(authorKey)); host.addTerm(kw('author')); },
    }] : []),
    ...(!loose && item.screen_name ? [{
      label: L('card.menu.openProfile', item.screen_name),
      icon: <ExternalLink size={z} />,
      run: () => window.open(`https://x.com/${item.screen_name}`, '_blank', 'noopener'),
    }] : []),
    'separator',
    {
      label: L('card.menu.tagMedia'),
      icon: <Tag size={z} />,
      run: () => void openTagPicker({ item, post, initialScope: 'media' }),
    },
    ...(!loose ? [{
      label: L('card.menu.tagPost'),
      icon: <Layers size={z} />,
      run: () => void openTagPicker({ item, post, initialScope: 'post' }),
    }] : []),
    ...(pending.length ? [{
      label: L('card.menu.approveAll'),
      icon: <BadgeCheck size={z} />,
      run: async () => { for (const t of pending) await addTag(item, t.label); libraryChanged(); },
    }] : []),
    ...(taggers.length ? [{
      label: L('card.menu.retag'),
      icon: <Sparkles size={z} />,
      children: taggers.map((m) => ({
        label: m.id === currentTagger ? `★ ${m.title}` : m.title,
        children: [
          { label: L('card.menu.retagAdd'), run: () => void retagMedia([ref], m.id, false) },
          { label: L('card.menu.retagReplace'), run: () => void retagMedia([ref], m.id, true) },
        ],
      })),
    }] : []),
    ...(item.tags.length ? [{
      label: L('card.menu.sources'),
      icon: <Info size={z} />,
      run: () => showTagSources(item),
    }] : []),
    'separator',
    ...item.tags.map((t) => ({
      label: t.label,
      icon: isAI(t.origin) ? (isUser(t.origin) ? <BadgeCheck size={z} /> : <Sparkles size={z} />) : <Tag size={z} />,
      children: tagMenu(item, t, host),
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
        try {
          const outcome = await core.read<string>(core.b.tl_repair(item.media_id));
          libraryChanged();
          if (outcome === 'replaced_new') await alertMessage(L('repair.replacedNew.title'), L('repair.replacedNew.message'));
          else if (outcome === 'from_peers') await alertMessage(L('repair.fromPeers.title'), L('repair.fromPeers.message'));
          else toast(L('repair.fixed'));
        } catch (e) {
          toast(`${L('repair.failed')}: ${L(String((e as Error).message))}`);
        }
      },
    }] : []),
    'separator',
    { label: L('card.menu.deleteMedia'), icon: <Trash2 size={z} />, danger: true, run: () => void runAction('trash', { media: [item.media_id] }, (n) => L('trash.moved', n)) },
    ...(!loose ? [{ label: L('card.menu.deletePost'), icon: <Trash2 size={z} />, danger: true, run: () => void runAction('trash', { posts: [item.post_id] }, (n) => L('trash.moved', n)) }] : []),
  ];
}

/** The menu of one tag of one media (the card menu's tag rows and a right-click on a tag pill). */
export function tagMenu(item: FeedItem, t: TagView, host: CardMenuHost): MenuEntry[] {
  const deleteTag = async () => {
    await removeTag(item, t.label);
    libraryChanged();
    toast(L('tag.deleted', t.label), {
      label: L('common.undo'),
      run: async () => {
        if (isAI(t.origin)) await addTag(item, t.label, true);
        if (isUser(t.origin)) await addTag(item, t.label);
        libraryChanged();
      },
    });
  };
  return [
    {
      label: L('card.menu.onlyTag'),
      icon: <Filter size={z} />,
      run: () => { host.addTerm(quoteSearchWord(t.label)); host.addTerm(kw('tags')); },
    },
    { label: L('card.menu.searchTag'), icon: <Search size={z} />, run: () => host.addTerm(quoteSearchWord(t.label)) },
    ...(isAI(t.origin) && !isUser(t.origin) ? [{ label: L('card.menu.approve'), icon: <BadgeCheck size={z} />, run: async () => { await addTag(item, t.label); libraryChanged(); } }] : []),
    {
      label: L('card.menu.renameTag'),
      icon: <Pencil size={z} />,
      run: async () => {
        const to = await prompt(L('card.menu.renameTag'), { initial: t.label });
        const next = to?.trim().toLowerCase();
        if (next && next !== t.label) {
          try {
            await core.read(core.b.tl_rename_tag(t.label, next));
            libraryChanged();
            toast(L('tags.renamed'));
          } catch (e) {
            toast(e instanceof Error ? L(e.message) : L('common.notDone'));
          }
        }
      },
    },
    'separator',
    { label: L('card.menu.deleteTag'), icon: <X size={z} />, danger: true, run: () => void deleteTag() },
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
