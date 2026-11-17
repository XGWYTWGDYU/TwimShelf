// Shared building blocks. Pages build on these so the whole app looks alike; see ui.css.
import { useEffect, useRef, type ReactNode } from 'react';
import './ui.css';

export function Page({ title, actions, children, back }: { title: ReactNode; actions?: ReactNode; children: ReactNode; back?: () => void }) {
  return (
    <div className="page">
      <header className="page-head">
        {back && <button className="icon-btn" onClick={back} aria-label="Back">‹</button>}
        <h1>{title}</h1>
        <div className="page-actions">{actions}</div>
      </header>
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
      {trailing !== undefined ? <span className="row-trailing">{trailing}</span> : onClick ? <span className="row-chevron">›</span> : null}
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

export function TextField({ value, onChange, placeholder, type = 'text', autoFocus, onEnter }: {
  value: string; onChange: (v: string) => void; placeholder?: string; type?: string; autoFocus?: boolean; onEnter?: () => void;
}) {
  return <input className="field" type={type} value={value} placeholder={placeholder} autoFocus={autoFocus}
    onChange={(e) => onChange(e.target.value)} onKeyDown={(e) => { if (e.key === 'Enter' && !e.nativeEvent.isComposing) onEnter?.(); }} />;
}

export function Progress({ value }: { value?: number }) {
  return <div className="progress">{value === undefined ? <div className="progress-indeterminate" /> : <div style={{ width: `${Math.round(Math.min(1, Math.max(0, value)) * 100)}%` }} />}</div>;
}

export function Spinner() {
  return <span className="spinner" aria-label="Loading" />;
}

export function Empty({ icon, title, children }: { icon?: ReactNode; title: ReactNode; children?: ReactNode }) {
  return <div className="empty">{icon && <div className="empty-icon">{icon}</div>}<div className="empty-title">{title}</div>{children}</div>;
}

/** A modal dialog; Esc and a click outside close it. */
export function Dialog({ title, children, actions, onClose, wide }: { title?: ReactNode; children?: ReactNode; actions?: ReactNode; onClose: () => void; wide?: boolean }) {
  const box = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const key = (e: KeyboardEvent) => { if (e.key === 'Escape') { e.stopPropagation(); onClose(); } };
    window.addEventListener('keydown', key, true);
    box.current?.focus();
    return () => window.removeEventListener('keydown', key, true);
  }, [onClose]);
  return (
    <div className="dialog-scrim" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <div className={`dialog${wide ? ' dialog-wide' : ''}`} ref={box} tabIndex={-1} role="dialog">
        {title && <h3 className="dialog-title">{title}</h3>}
        {children && <div className="dialog-body">{children}</div>}
        {actions && <div className="dialog-actions">{actions}</div>}
      </div>
    </div>
  );
}
