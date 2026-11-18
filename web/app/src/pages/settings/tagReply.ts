// A model's reply as tags, by the rules every app shares (scripts/checks/ai_tags/cases.json): a list
// in brackets (after a reasoning block, inside a code fence or a `{"tags": …}`, cut off by the
// length limit, with single quotes), or, from a reply with no brackets at all, a list split at commas
// and the like. What is no tag in a good list (`}`, a number) is left out. A reply that is no list,
// or holds nothing but such pieces, is 'ai.err.badReply'; an empty list is 'ai.err.noTags'.
const BAD = 'ai.err.badReply';
// How models mark their reasoning, and a plain reply that is reasoning without any mark.
const THINKING_ENDS = ['</think>', '</thinking>', '</reasoning>', '</reason>', '[/think]', '◁/think▷', '</seed:think>', '<channel|>', '<|end_of_thought|>', '<|channel|>final<|message|>'];
const THINKING_STARTS = ['<think>', '<thinking>', '<reasoning>', '<reason>', '[think]', '◁think▷', '<seed:think>', '<|channel>thought', '<|channel|>analysis', '<|begin_of_thought|>'];
const THINKING_ALOUD = /^((thinking process|thinking|thoughts?|reasoning|analysis)\s*[:：]|let me|let's|okay,|ok,|hmm|the user|the image|this image|思考|嗯|好的|首先|用户)/i;
const CLOSERS: Record<string, string> = { '"': '"', "'": "'", '“': '”', '‘': '’' };

/** The entries between a list's brackets. `cutOff`: the reply stopped inside the list. */
function listItems(c: string, cutOff: boolean): string[] {
  const items: string[] = [];
  let i = 0;
  while (i < c.length) {
    if (c[i] === ',' || /\s/.test(c[i])) { i++; continue; }
    const close = CLOSERS[c[i]];
    if (close) {
      let word = '', j = i + 1, closed = false;
      while (j < c.length) {
        if (c[j] === '\\' && j + 1 < c.length) {
          const e = c[j + 1];
          if ('ntr'.includes(e)) { word += ' '; j += 2; }
          else if (e === 'u') {
            const hex = c.slice(j + 2, j + 6);
            if (!/^[0-9a-fA-F]{4}$/.test(hex)) throw new Error(BAD);
            word += String.fromCharCode(parseInt(hex, 16));
            j += 6;
          } else { word += e; j += 2; }
          continue;
        }
        if (c[j] === close) {
          // an apostrophe inside a word in single quotes (dog's) is not the end
          let k = j + 1;
          while (k < c.length && /\s/.test(c[k])) k++;
          if (close !== "'" || k >= c.length || c[k] === ',') { closed = true; j++; break; }
        }
        word += c[j++];
      }
      if (!closed) break;
      items.push(word);
      i = j;
    } else {
      let j = c.indexOf(',', i);
      if (j < 0) j = c.length;
      const word = c.slice(i, j).trim();
      if (/[[\]{}]/.test(word)) throw new Error(BAD);
      if (!(cutOff && j === c.length) && Number.isNaN(Number(word)) && !['null', 'true', 'false'].includes(word)) items.push(word);
      i = j;
    }
  }
  return items;
}

/** What follows the model's reasoning. Reasoning that never ended (the length limit) is no answer. */
function withoutThinking(raw: string): string {
  let text = raw;
  for (const end of THINKING_ENDS) {
    const at = text.toLowerCase().lastIndexOf(end);
    if (at >= 0) text = text.slice(at + end.length);
  }
  const lower = text.toLowerCase();
  if (THINKING_STARTS.some((start) => lower.includes(start))) throw new Error(BAD);
  return text;
}

/** What turns a model's reasoning off, as this service spells it. Services that answer with the
 *  result alone get nothing; the rest of the world (local servers) gets the usual words. */
export function thinkingOff(host: string): Record<string, unknown> {
  const h = host.toLowerCase();
  const at = (d: string) => h === d || h.endsWith(`.${d}`);
  if (at('openai.com') || at('openai.azure.com') || at('x.ai') || at('anthropic.com')) return {};
  if (at('deepseek.com') || at('bigmodel.cn') || at('z.ai')) return { thinking: { type: 'disabled' } };
  if (at('aliyuncs.com') || at('siliconflow.cn') || at('siliconflow.com')) return { enable_thinking: false };
  if (at('openrouter.ai')) return { reasoning: { enabled: false } };
  if (at('googleapis.com')) return { reasoning_effort: 'none' };
  return { think: false, enable_thinking: false, chat_template_kwargs: { enable_thinking: false } };
}

export function parseTags(raw: string): string[] {
  let text = withoutThinking(raw).trim();
  if (text.startsWith('```')) {
    const nl = text.indexOf('\n');
    text = nl < 0 ? '' : text.slice(nl + 1).trim();
    if (text.endsWith('```')) text = text.slice(0, -3).trim();
  }
  let items: string[];
  const a = text.indexOf('['), b = text.lastIndexOf(']');
  if (a >= 0 || b >= 0) {
    if (a < 0 || (b >= 0 && b < a)) throw new Error(BAD);
    const before = text.slice(0, a).trim();
    const after = b < 0 ? '' : text.slice(b + 1).trim();
    const wrapped = before.startsWith('{') && !/[[\]{}]/.test(before.slice(1)) && (after === '}' || b < 0);
    if (!wrapped && /[[\]{}]/.test(before + after)) throw new Error(BAD);
    items = listItems(text.slice(a + 1, b < 0 ? text.length : b), b < 0);
  } else {
    if (THINKING_ALOUD.test(text)) throw new Error(BAD);
    text = text.replace(/^[^,，、;；\n:：{}"]{1,24}[:：]\s*/, '');
    if (/[{}:"]/.test(text)) throw new Error(BAD);
    items = text.split(/[,，、;；\n#]/);
  }
  const edge = /^[\s"'“”[\]()（）。.]+|[\s"'“”[\]()（）。.]+$/g;
  const segments = new Intl.Segmenter();
  const seen = new Set<string>();
  const result: string[] = [];
  let pieces = false;
  for (const item of items) {
    const clean = item.replace(edge, '').toLowerCase();
    if (!clean) continue;
    // eslint-disable-next-line no-control-regex
    if (/[{}[\]<>:"\\`\x00-\x1F\x7F]/.test(clean) || /^[\x21-\x2F\x3A-\x40\x5B-\x60\x7B-\x7E\s]+$/.test(clean)) { pieces = true; continue; }
    if ([...segments.segment(clean)].length <= 12 && !seen.has(clean)) { seen.add(clean); result.push(clean); }
    if (result.length === 12) break;
  }
  if (!result.length) throw new Error(pieces ? BAD : 'ai.err.noTags');
  return result;
}
