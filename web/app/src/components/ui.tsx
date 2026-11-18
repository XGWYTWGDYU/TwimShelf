// Shared building blocks. Pages build on these so the whole app looks alike; see ui.css.
import { useEffect, useId, useRef, type ReactNode } from 'react';
import { L } from '@twimshelf/core';
import { ChevronRight } from 'lucide-react';
import { Toolbar } from './Toolbar';
import './ui.css';

export function Page({ title, subtitle, actions, children, back }: {
  title: ReactNode; subtitle?: ReactNode; actions?: ReactNode; children: ReactNode; back?: () => void;
}) {
  return (
    <div className="page">
      <Toolbar title={title} subtitle={subtitle} back={back}>{actions}</Toolbar>
      <div className="page-body">{children}</div>
    </div>
  );
}

/** A titled group of rows, like a settings section. */
export function Section({ title, footer, children }: { title?: ReactNode; footer?: ReactNode; children: ReactNode }) {
  return (
    <section className="section">
      {title && <h2 className="section-title">{title}</h2>}
      <div className="section-box">{children}</div>
      {footer && <p className="section-footer">{footer}</p>}
    </section>
  );
}

export function Row({ icon, title, subtitle, trailing, onClick, danger }: {
  icon?: ReactNode; title: ReactNode; subtitle?: ReactNode; trailing?: ReactNode; onClick?: () => void; danger?: boolean;
}) {
  const Tag = onClick ? 'button' : 'div';
  return (
    <Tag className={`row${onClick ? ' row-click' : ''}${danger ? ' row-danger' : ''}`} onClick={onClick}>
      {icon && <span className="row-icon">{icon}</span>}
      <span className="row-text">
        <span className="row-title">{title}</span>
        {subtitle && <span className="row-subtitle">{subtitle}</span>}
      </span>
      {trailing !== undefined ? <span className="row-trailing">{trailing}</span> : onClick ? <span className="row-chevron"><ChevronRight size={14} strokeWidth={2.2} /></span> : null}
    </Tag>
  );
}

export function Button({ children, onClick, kind = 'normal', disabled, type = 'button' }: {
  children: ReactNode; onClick?: () => void; kind?: 'normal' | 'primary' | 'danger' | 'plain'; disabled?: boolean; type?: 'button' | 'submit';
}) {
  return <button type={type} className={`btn btn-${kind}`} onClick={onClick} disabled={disabled}>{children}</button>;
}

export function Toggle({ checked, onChange, disabled, label }: { checked: boolean; onChange: (v: boolean) => void; disabled?: boolean; label?: string }) {
  return (
    <button role="switch" aria-checked={checked} aria-label={label} disabled={disabled}
      className={`toggle${checked ? ' on' : ''}`} onClick={() => onChange(!checked)}><span /></button>
  );
}

export function TextField({ value, onChange, placeholder, type = 'text', autoFocus, selectOnFocus, onEnter }: {
  value: string; onChange: (v: string) => void; placeholder?: string; type?: string; autoFocus?: boolean; selectOnFocus?: boolean; onEnter?: () => void;
}) {
  return <input className="field" type={type} value={value} placeholder={placeholder} autoFocus={autoFocus}
    onFocus={selectOnFocus ? (e) => e.currentTarget.select() : undefined}
    onChange={(e) => onChange(e.target.value)} onKeyDown={(e) => { if (e.key === 'Enter' && !e.nativeEvent.isComposing) onEnter?.(); }} />;
}

export function Progress({ value }: { value?: number }) {
  return <div className="progress">{value === undefined ? <div className="progress-indeterminate" /> : <div style={{ width: `${Math.round(Math.min(1, Math.max(0, value)) * 100)}%` }} />}</div>;
}

export function Spinner() {
  return <span className="spinner" aria-label={L('web.loading')} />;
}

export function Empty({ icon, title, children }: { icon?: ReactNode; title: ReactNode; children?: ReactNode }) {
  return <div className="empty">{icon && <div className="empty-icon">{icon}</div>}<div className="empty-title">{title}</div>{children}</div>;
}

/** The dialogs open now, the newest last: Esc belongs to the one on top. */
const openDialogs: object[] = [];

/** A modal dialog; Esc closes it, and so does a click outside unless it is `modal` (it asks something). */
export function Dialog({ title, children, actions, onClose, wide, modal }: { title?: ReactNode; children?: ReactNode; actions?: ReactNode; onClose: () => void; wide?: boolean; modal?: boolean }) {
  const box = useRef<HTMLDivElement>(null);
  const titleId = useId();
  const close = useRef(onClose);
  close.current = onClose;
  useEffect(() => {
    const previous = document.activeElement;
    const self = {};
    openDialogs.push(self);
    const key = (e: KeyboardEvent) => {
      if (e.key !== 'Escape' || openDialogs[openDialogs.length - 1] !== self || document.querySelector('.menu-scrim')) return;
      e.stopPropagation();
      close.current();
    };
    window.addEventListener('keydown', key, true);
    if (!box.current?.contains(document.activeElement)) box.current?.focus();
    return () => {
      window.removeEventListener('keydown', key, true);
      openDialogs.splice(openDialogs.indexOf(self), 1);
      if (previous instanceof HTMLElement && previous.isConnected) previous.focus();
    };
  }, []);
  return (
    <div className="dialog-scrim" onMouseDown={(e) => { if (!modal && e.target === e.currentTarget) onClose(); }}>
      <div className={`dialog${wide ? ' dialog-wide' : ''}`} ref={box} tabIndex={-1} role="dialog" aria-modal="true" aria-labelledby={title ? titleId : undefined}>
        {title && <h3 className="dialog-title" id={titleId}>{title}</h3>}
        {children && <div className="dialog-body">{children}</div>}
        {actions && <div className="dialog-actions">{actions}</div>}
      </div>
    </div>
  );
}
