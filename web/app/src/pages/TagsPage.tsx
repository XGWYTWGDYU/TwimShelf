import { useState } from 'react';
import { L, type TagCount } from '@twimshelf/core';
import { ArrowUpDown, ArrowUpRight, Ellipsis, Search, Tags, X } from 'lucide-react';
import { Empty, Page } from '../components/ui';
import { change, LoadState, useTask } from '../components/libraryControls';
import { openMenu, openMenuBelow, type MenuEntry } from '../components/Menu';
import { alertMessage, choose, pickFolder, prompt } from '../components/pickers';
import { toast } from '../components/toast';
import { core } from '../lib/core';
import { useAsync, useStore } from '../lib/hooks';
import { libraryVersion } from '../lib/library';
import { go } from '../lib/router';
import { SegmentedControl } from './settings/settingsControls';
import './settings/settings.css';

const sortKeys = ['count', 'user', 'ai', 'label'] as const;
type Sort = typeof sortKeys[number];
type Show = 'all' | 'mine' | 'ai' | 'both';

function readSort(): Sort {
  try {
    const v = localStorage.getItem('tags.sort') as Sort | null;
    if (v && sortKeys.includes(v)) return v;
  } catch { /* ignore */ }
  return 'count';
}

function writeSort(s: Sort): void {
  try { localStorage.setItem('tags.sort', s); } catch { /* ignore */ }
}

function sortTitle(s: Sort): string {
  switch (s) {
    case 'count': return L('tags.sort.count');
    case 'user': return L('tags.sort.mine');
    case 'ai': return L('tags.sort.ai');
    case 'label': return L('common.name');
  }
}

function commonCount(t: TagCount): number {
  return Math.max(0, t.user + t.ai - t.count);
}

export default function TagsPage({ back }: { back?: () => void }) {
  const version = useStore(libraryVersion);
  const { data, error, reload } = useAsync(() => core.read<TagCount[]>(core.b.tl_all_tags()), [version]);
  const [sort, setSort] = useState<Sort>(readSort);
  const [show, setShow] = useState<Show>('all');
  const [query, setQuery] = useState('');
  const task = useTask();

  const all = data ?? [];
  const aiTotal = all.reduce((sum, t) => sum + t.ai, 0);
  const q = query.trim().toLowerCase();

  const visible = all
    .filter((t) => (!q || t.label.toLowerCase().includes(q)))
    .filter((t) => {
      switch (show) {
        case 'mine': return t.user > 0;
        case 'ai': return t.ai > 0;
        case 'both': return commonCount(t) > 0;
        default: return true;
      }
    })
    .sort((a, b) => (sort === 'label' ? 0 : b[sort] - a[sort]) || a.label.localeCompare(b.label));

  async function confirmRemoveAI() {
    if (aiTotal <= 0) {
      await alertMessage(L('tags.noAI'));
      return;
    }
    const ok = await choose(
      L('tags.deleteAI.title', aiTotal),
      L('tags.deleteAI.message'),
      [L('tags.deleteAI.confirm')],
      { destructive: true },
    );
    if (ok == null) return;
    await task.run(async () => {
      await change(core.read(core.b.tl_remove_ai_tags()));
    });
  }

  async function renameTag(t: TagCount) {
    const next = (
      await prompt(
        L('tags.rename.title', t.label),
        { message: L('tags.rename.countMessage', t.count), placeholder: t.label, initial: t.label, action: L('common.done') },
      )
    )?.trim().toLowerCase();
    if (!next || next === t.label) return;
    await task.run(async () => {
      await change(core.read(core.b.tl_rename_tag(t.label, next)));
      toast(L('tags.renamed'));
    });
  }

  async function toFolder(t: TagCount) {
    const folder = (await pickFolder({ title: L('tags.toFolder.title', t.label, t.count) }))?.trim();
    if (!folder) return;
    await task.run(async () => {
      await core.read(core.b.tl_create_folder(folder)).catch(() => {});
      const n = await change(core.readJson<number>('tl_tag_to_folder', { label: t.label, folder }));
      await alertMessage(
        L('tags.toFolder.done', folder),
        n === t.count ? L('search.row.mediaCount', n) : L('tags.toFolder.partly', n),
      );
    });
  }

  async function deleteTag(t: TagCount) {
    const ok = await choose(
      L('tags.delete.title', t.label),
      L('tags.delete.message', t.count),
      [L('card.menu.deleteTag')],
      { destructive: true },
    );
    if (ok == null) return;
    await task.run(async () => {
      await change(core.read(core.b.tl_delete_tag(t.label)));
    });
  }

  function tagMenu(t: TagCount): MenuEntry[] {
    return [
      { label: L('tags.allToFolder', t.count), run: () => void toFolder(t) },
      'separator',
      { label: L('tags.renameOrMerge'), run: () => void renameTag(t) },
      { label: L('tags.deleteEllipsis'), danger: true, run: () => void deleteTag(t) },
    ];
  }

  const summary = all.length === 0
    ? ''
    : L('tags.total', all.length)
      + (visible.length === all.length ? '' : L('tags.shown', visible.length))
      + L('tags.hint.mac');

  return (
    <Page title={L('common.tags')} back={back}>
      {!data || error ? (
        <LoadState error={error} reload={reload} />
      ) : (
        <div className="tags-canvas">
          <div className="tags-toolbar">
            <div className="tags-toolbar-row1">
              <div className="tags-search-capsule">
                <Search size={14} strokeWidth={2} />
                <input
                  className="tags-search-input"
                  value={query}
                  placeholder={L('tags.filter')}
                  onChange={(e) => setQuery(e.target.value)}
                />
                {query && (
                  <button
                    type="button"
                    className="tags-search-clear"
                    aria-label={L('common.clear')}
                    onClick={() => setQuery('')}>
                    <X size={11} strokeWidth={2.5} />
                  </button>
                )}
              </div>

              <button
                type="button"
                className="btn"
                onClick={(e) => {
                  openMenuBelow(
                    e.currentTarget,
                    sortKeys.map((k) => ({
                      label: sortTitle(k),
                      checked: sort === k,
                      run: () => { setSort(k); writeSort(k); },
                    })),
                  );
                }}>
                <ArrowUpDown size={13} strokeWidth={2} />
                <span>{L('tags.sortBy')}{sortTitle(sort)}</span>
              </button>

              <button
                type="button"
                className="icon-btn"
                aria-label={L('grid.more')}
                onClick={(e) => openMenuBelow(e.currentTarget, [
                  {
                    label: L('tags.deleteAIEllipsis'),
                    danger: true,
                    disabled: aiTotal === 0 || task.busy,
                    run: () => void confirmRemoveAI(),
                  },
                ])}>
                <Ellipsis size={16} strokeWidth={2} />
              </button>
            </div>

            <div className="tags-toolbar-row2">
              <SegmentedControl<Show>
                value={show}
                onChange={setShow}
                options={[
                  { value: 'all', label: L('search.kw.all.word') },
                  { value: 'mine', label: L('search.kw.mine.word') },
                  { value: 'ai', label: L('search.kw.ai.word') },
                  { value: 'both', label: L('search.kw.common.word') },
                ]}
              />

              <div className="tags-legend">
                <span className="tags-legend-item">
                  <span className="tags-dot mine" />
                  <span>{L('search.kw.mine.word')}</span>
                </span>
                <span className="tags-legend-item">
                  <span className="tags-dot ai" />
                  <span>AI</span>
                </span>
                <span className="tags-legend-item">
                  <span className="tags-dot both" />
                  <span>{L('search.kw.common.word')}</span>
                </span>
              </div>
            </div>

            {summary && <p className="tags-summary">{summary}</p>}
          </div>

          {!all.length ? (
            <Empty icon={<Tags size={38} />} title={L('tags.none')}>{L('tags.none.message')}</Empty>
          ) : !visible.length ? (
            <Empty icon={<Search size={38} />} title={L('tags.noMatch')}>{L('tags.noMatch.message')}</Empty>
          ) : (
            <div className="tags-grid">
              {visible.map((t) => {
                const common = commonCount(t);
                const onlyMine = Math.max(0, t.user - common);
                const onlyAI = Math.max(0, t.ai - common);
                const total = Math.max(1, t.count);
                return (
                  <div
                    key={t.label}
                    className="tag-card"
                    onContextMenu={(e) => openMenu(e, tagMenu(t))}>
                    <div className="tag-card-head">
                      <span className="tag-card-label">{t.label}</span>
                      <span style={{ display: 'inline-flex', alignItems: 'center', gap: 2 }}>
                        <button
                          type="button"
                          className="icon-btn tag-card-action"
                          aria-label={L('grid.more')}
                          onClick={(e) => {
                            e.stopPropagation();
                            openMenuBelow(e.currentTarget, tagMenu(t));
                          }}>
                          <Ellipsis size={14} strokeWidth={2} />
                        </button>
                        <button
                          type="button"
                          className="icon-btn tag-card-action tag-card-arrow"
                          aria-label={L('tags.onlyInBrowse', t.label)}
                          title={L('tags.onlyInBrowse', t.label)}
                          onClick={() => go({ page: 'browse', q: t.label })}>
                          <ArrowUpRight size={13} strokeWidth={2.2} />
                        </button>
                      </span>
                    </div>

                    <div className="tag-card-count-row">
                      <span className="tag-card-count">{t.count.toLocaleString()}</span>
                      <span className="tag-card-unit">{L('tags.itemsUnit')}</span>
                    </div>

                    <div className="tag-card-bar">
                      {onlyMine > 0 && <span className="tag-card-bar-seg mine" style={{ flexGrow: onlyMine / total }} />}
                      {common > 0 && <span className="tag-card-bar-seg both" style={{ flexGrow: common / total }} />}
                      {onlyAI > 0 && <span className="tag-card-bar-seg ai" style={{ flexGrow: onlyAI / total }} />}
                    </div>

                    <div className="tag-card-stats">
                      {t.user > 0 && (
                        <span className="tag-card-stat">
                          <span className="tags-dot mine" />
                          <span>{L('search.kw.mine.word')} {t.user}</span>
                        </span>
                      )}
                      {t.ai > 0 && (
                        <span className="tag-card-stat">
                          <span className="tags-dot ai" />
                          <span>AI {t.ai}</span>
                        </span>
                      )}
                      {common > 0 && (
                        <span className="tag-card-stat">
                          <span className="tags-dot both" />
                          <span>{L('search.kw.common.word')} {common}</span>
                        </span>
                      )}
                    </div>
                  </div>
                );
              })}
            </div>
          )}
        </div>
      )}
    </Page>
  );
}
