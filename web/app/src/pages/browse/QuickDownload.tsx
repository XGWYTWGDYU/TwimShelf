// The download button beside the search field opens this card under it, as the native app's
// popover (QuickDownloadCard): links one per line (a double click pastes the clipboard's post
// links), the way to the full download page, and 下载 (⌘↩). It starts with the options saved on
// that page; the links are the page's own, and they go once the download has started.
import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { L, type DownloadRequest } from '@twimshelf/core';
import { Button } from '../../components/ui';
import { change, errorText } from '../../components/libraryControls';
import { alertMessage } from '../../components/pickers';
import { core } from '../../lib/core';
import { useStore } from '../../lib/hooks';
import { go } from '../../lib/router';
import { downloadLinks, parseLinks, savedDownloadOptions, withPastedLinks } from '../settings/downloadLinks';
import './QuickDownload.css';

const WIDTH = 380;

export function QuickDownload({ anchor, onClose }: { anchor: HTMLElement; onClose: () => void }) {
  const links = useStore(downloadLinks);
  const [busy, setBusy] = useState(false);
  const [pos, setPos] = useState<{ left: number; top: number; arrow: number }>();
  const card = useRef<HTMLDivElement>(null);
  const box = useRef<HTMLTextAreaElement>(null);

  // under the button, centred on it, and inside the window
  useLayoutEffect(() => {
    const place = () => {
      const r = anchor.getBoundingClientRect();
      const centre = r.left + r.width / 2;
      const left = Math.max(12, Math.min(centre - WIDTH / 2, window.innerWidth - WIDTH - 12));
      setPos({ left, top: r.bottom + 10, arrow: centre - left });
    };
    place();
    window.addEventListener('resize', place);
    return () => window.removeEventListener('resize', place);
  }, [anchor]);

  useEffect(() => { box.current?.focus(); }, []);

  // transient, as an NSPopover: a click elsewhere or Escape closes it
  useEffect(() => {
    const down = (e: MouseEvent) => {
      const t = e.target as Node;
      // (an alert the card raised, or a menu, is not "elsewhere")
      if (t instanceof Element && t.closest('.dialog-scrim, .menu-scrim')) return;
      if (!card.current?.contains(t) && !anchor.contains(t)) onClose();
    };
    const key = (e: KeyboardEvent) => {
      if (e.key !== 'Escape' || document.querySelector('.dialog-scrim, .menu-scrim')) return;
      e.stopPropagation();
      onClose();
    };
    window.addEventListener('mousedown', down, true);
    window.addEventListener('keydown', key, true);
    return () => { window.removeEventListener('mousedown', down, true); window.removeEventListener('keydown', key, true); };
  }, [anchor, onClose]);

  const empty = !links.trim();

  async function download() {
    if (busy) return;
    const { goodUrls, badUrls } = parseLinks(links);
    if (!goodUrls.length && !badUrls.length) return void alertMessage(L('settings.links.empty'));
    if (badUrls.length) return void alertMessage(L('settings.links.unrecognized'), badUrls.slice(0, 3).join('\n'));
    setBusy(true);
    try {
      const o = await savedDownloadOptions();
      const request: DownloadRequest = {
        urls: goodUrls, route: o.route, concurrency: o.concurrency, interval_ms: o.intervalMs, folder: o.folder,
        revive: true, mark_recent: false,
      };
      await change(core.read(core.b.tl_download_start(JSON.stringify(request))));
      downloadLinks.set('');
      onClose();
    } catch (error) {
      await alertMessage(L('common.couldNotStartDownload'), errorText(error));
    } finally {
      setBusy(false);
    }
  }

  async function paste() {
    try { downloadLinks.set(withPastedLinks(downloadLinks.get(), await navigator.clipboard.readText())); } catch { /* no clipboard here */ }
  }

  // on the page's body: the search field's glass (backdrop-filter) would hold a fixed card inside it
  return createPortal(
    <div ref={card} className="quick-download" role="dialog" aria-label={L('common.downloadPosts')}
      style={pos ? { left: pos.left, top: pos.top, width: WIDTH, ['--arrow' as string]: `${pos.arrow}px` } : { visibility: 'hidden' }}>
      <div className="quick-download-head">
        <div className="quick-download-title">{L('common.downloadPosts')}</div>
        <div className="quick-download-note">{L('mac.quick.footer')}</div>
      </div>
      <textarea
        ref={box}
        className="quick-download-links"
        value={links}
        placeholder={L('mac.quick.placeholder')}
        aria-label={L('mac.quick.placeholder')}
        spellCheck={false}
        onChange={(e) => downloadLinks.set(e.target.value)}
        onDoubleClick={() => void paste()}
        onKeyDown={(e) => { if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); void download(); } }}
      />
      <div className="quick-download-actions">
        <button type="button" className="quick-download-link" onClick={() => { onClose(); go({ page: 'settings', sub: 'downloads' }); }}>
          {L('mac.quick.settings')}
        </button>
        <Button kind="primary" disabled={empty || busy} onClick={() => void download()}>{L('common.download')}</Button>
      </div>
    </div>,
    document.body,
  );
}
