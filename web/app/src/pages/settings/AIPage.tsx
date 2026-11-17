import { useState } from 'react';
import { L, type AiFailure, type ModelDownloadStatus, type ModelInfo } from '@twimshelf/core';
import { Cpu, Sparkles } from 'lucide-react';
import { Button, Dialog, Progress, Row, Section, Toggle } from '../../components/ui';
import { change, Confirm, FileButton, LoadState, Select, useTask } from '../../components/libraryControls';
import { toast } from '../../components/toast';
import { core } from '../../lib/core';
import { useAsync, useInterval, useStore } from '../../lib/hooks';
import { libraryVersion } from '../../lib/library';
import { activeTagger, autoTag, defaultPrompt, deleteModel, externalModels, getPrompt, modelTitle, promptFields,
  runTagging, saveModel, selectTagger, setAuto, setSetting, stopTagging, tagging, testModel, type ExternalModel, type Prompt } from './aiTagging';
import { ModelProgress } from './ModelHubPage';
import { deliver, info, outPath, removeFile, size, upload } from './serverFiles';
import { FieldRow, SettingsScreen, TextArea, settings, useNotice } from './settingsControls';

export default function AIPage() {
  const version = useStore(libraryVersion);
  const selected = useStore(activeTagger);
  const automatic = useStore(autoTag);
  const activity = useStore(tagging);
  const models = useAsync(externalModels, [version]);
  const counts = useAsync(() => core.read<[number, number]>(core.b.tl_ai_counts()), [version]);
  const failures = useAsync(() => core.read<AiFailure[]>(core.b.tl_ai_failures()), [version, activity.running]);
  const status = useAsync(() => core.read<ModelDownloadStatus | null>(core.b.tl_model_status()), []);
  const installed = useAsync(() => core.read<ModelInfo[]>(core.b.tl_models_installed()), [version, status.data?.repo, status.data?.finished]);
  const [edit, setEdit] = useState<ExternalModel>();
  const [externalDelete, setExternalDelete] = useState<ExternalModel>();
  const [localDelete, setLocalDelete] = useState<ModelInfo>();
  const [prompt, setPrompt] = useState<{ id: string; value: Prompt }>();
  const [retag, setRetag] = useState(false);
  const [replace, setReplace] = useState(false);
  const [showFailures, setShowFailures] = useState(false);
  const task = useTask();
  useInterval(status.reload, 1600);
  const model = models.data?.find((candidate) => candidate.id === selected);

  return <SettingsScreen title={L('models.tagging')}>
    <Section title={L('models.tagging')} footer={L('web.ai.browser')}>
      {counts.data && <Row icon={<Sparkles size={17} />} title={L('models.tagging')}
        trailing={L('web.ai.counts', counts.data[0], counts.data[1])} />}
      <Row title={L('models.defaultTagger')} trailing={<Select value={model?.id ?? ''} label={L('models.defaultTagger')}
        options={[{ value: '', label: L('web.ai.noModel') }, ...(models.data ?? []).map((entry) => ({ value: entry.id, label: modelTitle(entry) }))]}
        disabled={!models.data || activity.running} onChange={(id) => {
          selectTagger(id);
          if (id && automatic) void runTagging();
        }} />} />
      <Row title={L('models.autoTag')} trailing={<Toggle label={L('models.autoTag')} checked={automatic} disabled={!model}
        onChange={(value) => {
          setAuto(value);
          if (value) void runTagging();
          else stopTagging();
        }} />} />
      {activity.running ? <>
        <Row title={L('models.inProgress')} subtitle={L('web.ai.processed', activity.done)}
          trailing={<Button onClick={() => { setAuto(false); stopTagging(); }}>{L('models.stopTagging')}</Button>} />
        <div className="control-padded"><Progress /></div>
      </> : model && <Row title={L('models.tagging')} trailing={<div className="control-actions">
        <Button kind="primary" onClick={() => void runTagging()}>{L('web.ai.tagNow')}</Button>
        <Button onClick={() => { setReplace(false); setRetag(true); }}>{L('models.retagAllEllipsis')}</Button>
      </div>} />}
      {activity.error && <Row title={L(activity.error)} trailing={<Button onClick={() => void runTagging()}>{L('models.retry')}</Button>} />}
      {!!failures.data?.length && <Row title={L('models.failures')} trailing={failures.data.length} onClick={() => setShowFailures(true)} />}
    </Section>
    <Section title={L('models.external')}>
      {!models.data || models.error ? <LoadState error={models.error} reload={models.reload} /> : models.data.map((item) => <Row
        key={item.id} title={modelTitle(item)} subtitle={item.url}
        trailing={<div className="control-actions">
          <Button disabled={activity.running} onClick={() => setEdit(item)}>{L('web.edit')}</Button>
          <Button disabled={task.busy} onClick={() => void task.run(async () => {
            setPrompt({ id: item.id, value: await getPrompt(item.id) });
          })}>{L('models.promptSection')}</Button>
          <Button disabled={activity.running} onClick={() => setExternalDelete(item)}>{L('common.delete')}</Button>
        </div>} />)}
      <Row title={L('models.addExternalEllipsis')} onClick={() => setEdit({
        id: `ext:${crypto.getRandomValues(new Uint32Array(4)).join('-')}`, name: '', url: '', model: '',
      })} />
    </Section>
    <ModelProgress status={status.data} cancel={() => void task.run(async () => {
      await core.b.tl_model_cancel();
      status.reload();
    })} />
    <Section title={L('models.local')} footer={L('web.ai.local')}>
      {!installed.data || installed.error ? <LoadState error={installed.error} reload={installed.reload} /> :
        installed.data.map((item) => <Row key={item.id} icon={<Cpu size={17} />} title={item.repo || item.id}
          subtitle={L('models.installed', size(item.bytes))}
          trailing={<div className="control-actions">
            <Button disabled={task.busy} onClick={() => void task.run(async () => {
              const name = `${item.id.replaceAll('/', '-')}.zip`;
              const path = outPath(await info(), name);
              await core.read(core.b.tl_model_export_zip(item.id, path));
              await deliver(path, name);
            })}>{L('models.exportZip')}</Button>
            <Button onClick={() => setLocalDelete(item)}>{L('common.delete')}</Button>
          </div>} />)}
      <Row title={L('web.ai.importZip')} trailing={<FileButton label={L('web.chooseFile')} accept=".zip" disabled={task.busy}
        onPick={(file) => void task.run(async () => {
          const path = await upload(file);
          try {
            await change(core.read(core.b.tl_model_import(path)));
            toast(L('models.imported'));
          } finally {
            await removeFile(path).catch(() => {});
          }
        })} />} />
      <Row title={L('hub.title')} subtitle={L('hub.entry.detail')} onClick={() => settings('model-hub')} />
    </Section>
    {edit && <ExternalModelDialog initial={edit} onClose={() => setEdit(undefined)} />}
    {externalDelete && <Confirm title={L('models.delete.title', modelTitle(externalDelete))} action={L('common.delete')} danger
      onClose={() => setExternalDelete(undefined)} onConfirm={async () => {
        await change(deleteModel(externalDelete));
        if (externalDelete.id === selected) selectTagger('');
      }}>{L('models.external.delete')}</Confirm>}
    {localDelete && <Confirm title={L('models.delete.title', localDelete.repo || localDelete.id)} action={L('common.delete')} danger
      onClose={() => setLocalDelete(undefined)} onConfirm={() => change(core.read(core.b.tl_model_delete(localDelete.id)))}>
      {L('models.delete.message')}
    </Confirm>}
    {prompt && <Dialog wide title={L('models.promptSection')} onClose={() => setPrompt(undefined)} actions={<>
      <Button disabled={task.busy} onClick={() => setPrompt({ ...prompt, value: defaultPrompt() })}>{L('mac.prompt.reset')}</Button>
      <Button disabled={task.busy} onClick={() => setPrompt(undefined)}>{L('common.cancel')}</Button>
      <Button kind="primary" disabled={task.busy} onClick={() => void task.run(async () => {
        await change(setSetting(`ai.modelPrompt.${prompt.id}`, JSON.stringify(prompt.value)));
        setPrompt(undefined);
        toast(L('prompt.saved'));
      })}>{L('mac.prompt.save')}</Button>
    </>}>
      <div className="control-stack">
        {promptFields.map((field) => {
          const key = { system: 'system', prompt: 'question', existing: 'existing', vocabulary: 'libraryTags', context: 'postText' }[field];
          return <div key={field}>
            <TextArea label={L(`prompt.${key}`)} value={prompt.value[field]}
              onChange={(value) => setPrompt({ ...prompt, value: { ...prompt.value, [field]: value } })} />
            <small>{L(`prompt.${key}.footer`)}</small>
          </div>;
        })}
      </div>
    </Dialog>}
    {retag && <Confirm title={L('models.retagAll')} action={L('models.retagAll')} onClose={() => setRetag(false)}
      onConfirm={async () => { void runTagging({ retag: true, replace }); }}>
      <p>{L('models.retag.oldMessage')}</p>
      <Row title={L('models.retag.replace')} trailing={<Toggle label={L('models.retag.replace')} checked={replace} onChange={setReplace} />} />
    </Confirm>}
    {showFailures && <Dialog wide title={L('models.failures.title')} onClose={() => setShowFailures(false)} actions={<>
      <Button onClick={() => setShowFailures(false)}>{L('common.close')}</Button>
      <Button disabled={task.busy || activity.running} onClick={() => void task.run(async () => {
        await change(core.read(core.b.tl_ai_failures_clear()));
        failures.reload();
        setShowFailures(false);
        void runTagging();
      })}>{L('models.retry')}</Button>
    </>}>
      {(failures.data ?? []).slice(0, 30).map((failure) => <Row key={failure.media_id + failure.model}
        title={L('models.failure.line', failure.media_id.slice(0, 12), failure.attempts, L(failure.reason))} />)}
      {(failures.data?.length ?? 0) > 30 && <p>{L('models.failures.more', failures.data!.length - 30)}</p>}
      <p>{L('models.failures.footer')}</p>
    </Dialog>}
  </SettingsScreen>;
}

function ExternalModelDialog({ initial, onClose }: { initial: ExternalModel; onClose: () => void }) {
  const [model, setModel] = useState(initial);
  const [key, setKey] = useState('');
  const [clear, setClear] = useState(false);
  const task = useTask();
  const notice = useNotice();
  const update = (field: 'name' | 'url' | 'model') => (value: string) => setModel({ ...model, [field]: value });
  const normalized = { ...model, name: model.name.trim(), url: model.url.trim(), model: model.model.trim() };
  const valid = !!normalized.url && (!key.trim() || !!normalized.model);

  return <>
    {!notice.dialog && <Dialog title={L(initial.url ? 'web.edit' : 'models.addExternal')}
      onClose={() => { if (!task.busy) onClose(); }} actions={<>
        <Button disabled={task.busy} onClick={onClose}>{L('common.cancel')}</Button>
        <Button disabled={task.busy || !valid} onClick={() => void task.run(async () => {
          const labels = await testModel(normalized, key.trim(), clear);
          notice.show(L('models.external.success'), labels.length ? labels.join(L('list.separator')) : L('models.external.noTags'));
        })}>{L('models.external.test')}</Button>
        <Button kind="primary" disabled={task.busy || !valid} onClick={() => void task.run(async () => {
          await change(saveModel(normalized, key.trim(), clear));
          if (!activeTagger.get()) selectTagger(model.id);
          onClose();
        })}>{L('common.save')}</Button>
      </>}>
      <FieldRow label={L('models.external.field.name')} value={model.name} onChange={update('name')} />
      <FieldRow label={L('models.external.field.url')} value={model.url} onChange={update('url')} />
      <FieldRow label={L('models.external.field.model')} value={model.model} onChange={update('model')} />
      <FieldRow label={L('models.external.field.key')} type="password" value={key} onChange={setKey} />
      {initial.url && <Row title={L('web.ai.clearKey')} trailing={<Toggle checked={clear} onChange={setClear} label={L('web.ai.clearKey')} />} />}
      <p>{L('web.ai.externalFooter')}</p>
    </Dialog>}
    {notice.dialog}
  </>;
}
