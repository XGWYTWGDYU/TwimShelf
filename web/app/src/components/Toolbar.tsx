// The window's toolbar over the content, as the native one (AppDelegate.refreshChrome): 52 px,
// a Back chevron where there is a level above, the page's title and subtitle (on a grid page a
// capsule of glass, since the photos scroll under it: MacGlassTitle), then the page's own
// controls on the right as glass buttons. It is the window's title bar too (drag to move).
import type { ReactNode } from 'react';
import { ChevronLeft } from 'lucide-react';
import { L } from '@twimshelf/core';
import './Toolbar.css';

export function Toolbar({ title, subtitle, back, pill, children, overlay, center }: {
  title?: ReactNode;
  subtitle?: ReactNode;
  back?: () => void;
  /** The title on glass (a grid page: the photos scroll under the toolbar). */
  pill?: boolean;
  /** Over the content (it scrolls underneath), rather than above it. */
  overlay?: boolean;
  /** Something in the middle that takes the free room (浏览's search). */
  center?: ReactNode;
  children?: ReactNode;
}) {
  return (
    <header className={`toolbar${overlay ? ' toolbar-overlay' : ''}`}>
      {back && <ToolButton label={L('mac.toolbar.back')} onClick={back}><ChevronLeft size={18} strokeWidth={2} /></ToolButton>}
      {title !== undefined && (pill ? (
        <div className="toolbar-pill glass">
          <div className="toolbar-title">{title}</div>
          {subtitle ? <div className="toolbar-subtitle">{subtitle}</div> : null}
        </div>
      ) : (
        <div className="toolbar-titles">
          <div className="toolbar-title">{title}</div>
          {subtitle ? <div className="toolbar-subtitle">{subtitle}</div> : null}
        </div>
      ))}
      <div className="toolbar-space">{center}</div>
      {children && <div className="toolbar-items">{children}</div>}
    </header>
  );
}

/** A toolbar button: a symbol (or a word) on a capsule of glass. */
export function ToolButton({ label, onClick, children, disabled, prominent, className, onMouseDown }: {
  label: string; onClick?: (e: React.MouseEvent<HTMLButtonElement>) => void; children?: ReactNode; disabled?: boolean; prominent?: boolean; className?: string;
  onMouseDown?: (e: React.MouseEvent<HTMLButtonElement>) => void;
}) {
  const text = typeof children === 'string';
  return (
    <button className={`tool-btn glass${text ? ' tool-text' : ''}${prominent ? ' tool-prominent' : ''}${className ? ' ' + className : ''}`}
      aria-label={label} title={text ? undefined : label} disabled={disabled} onClick={onClick} onMouseDown={onMouseDown}>
      {children}
    </button>
  );
}

/** Several buttons on one capsule (− and + of the zoom). */
export function ToolGroup({ children }: { children: ReactNode }) {
  return <div className="tool-group glass">{children}</div>;
}

export function ToolSegment({ label, onClick, disabled, children }: { label: string; onClick: () => void; disabled?: boolean; children: ReactNode }) {
  return <button className="tool-seg" aria-label={label} title={label} disabled={disabled} onClick={onClick}>{children}</button>;
}
