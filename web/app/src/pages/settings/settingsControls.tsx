import { useState, type ReactNode } from 'react';
import { L } from '@twimshelf/core';
import { Button, Dialog, Page, Progress, Row, TextField } from '../../components/ui';
import { Select, type Option } from '../../components/libraryControls';
import { useStore } from '../../lib/hooks';
import { folders } from '../../lib/library';
import { go } from '../../lib/router';

export function settings(sub?: string) {
  go({ page: 'settings', sub });
}

export function SettingsScreen({ title, actions, children, parent }: {
  title: string; actions?: ReactNode; children: ReactNode; parent?: string;
}) {
  return <Page title={title} actions={actions} back={() => settings(parent)}>{children}</Page>;
}

export function FolderChoice({ title, value, onChange, disabled, extra = [], empty = L('common.notIntoFolder') }: {
  title: string; value: string; onChange: (name: string) => void; disabled?: boolean; extra?: Option[]; empty?: string;
}) {
  const overview = useStore(folders);
  const options = [
    { value: '', label: empty },
    ...(overview?.folders ?? []).map(({ name }) => ({ value: name, label: name })),
    ...extra,
  ];
  if (!options.some((option) => option.value === value)) options.splice(1, 0, { value, label: value });
  return <Row title={title} trailing={<Select label={title} value={value} options={options} onChange={onChange} disabled={disabled} />} />;
}

export function FieldRow({ label, value, onChange, type, subtitle, placeholder }: {
  label: string; value: string; onChange: (value: string) => void; type?: string; subtitle?: string; placeholder?: string;
}) {
  return <Row title={label} subtitle={subtitle} trailing={<TextField value={value} onChange={onChange} type={type} placeholder={placeholder ?? label} />} />;
}

export function TextArea({ label, value, onChange, placeholder, disabled }: {
  label: string; value: string; onChange: (value: string) => void; placeholder?: string; disabled?: boolean;
}) {
  return <label className="control-field-label">{label}<textarea className="field control-textarea" value={value}
    placeholder={placeholder} disabled={disabled} onChange={(event) => onChange(event.target.value)} /></label>;
}

export function ProgressRow({ title, subtitle, value, onCancel }: {
  title: string; subtitle?: string; value?: number; onCancel?: () => void;
}) {
  return <>
    <Row title={title} subtitle={subtitle} trailing={onCancel && <Button onClick={onCancel}>{L('common.cancel')}</Button>} />
    <div className="control-padded"><Progress value={value} /></div>
  </>;
}

export function ResultDialog({ title, children, close }: { title: string; children: ReactNode; close: () => void }) {
  return <Dialog title={title} onClose={close}
    actions={<Button kind="primary" onClick={close}>{L('common.ok')}</Button>}>{children}</Dialog>;
}

export function useNotice() {
  const [notice, setNotice] = useState<{ title: string; text: ReactNode }>();
  return {
    show: (title: string, text: ReactNode) => setNotice({ title, text }),
    dialog: notice && <ResultDialog title={notice.title} close={() => setNotice(undefined)}>{notice.text}</ResultDialog>,
  };
}
