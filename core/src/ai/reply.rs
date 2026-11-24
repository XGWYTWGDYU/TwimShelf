//! A vision model's reply as tags, by the rules every app shares (scripts/checks/ai_tags/cases.json):
//! a list in brackets (after a reasoning block, inside a code fence or a `{"tags": …}`, cut off by
//! the length limit, with single quotes), or, from a reply with no brackets at all, a list split at
//! commas and the like. What is no tag in a good list (`}`, a number) is left out. A reply that is no
//! list, or holds nothing but such pieces, is [`ReplyError::Bad`]; an empty list is
//! [`ReplyError::None`]. Either way the analysis failed, and nothing is written.
use regex::Regex;
use std::collections::HashSet;
use std::sync::OnceLock;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReplyError {
    /// Not a valid list of tags.
    Bad,
    /// A valid list without a tag in it.
    None,
}

/// At most this many tags from one reply, each at most this many characters.
const MAX_TAGS: usize = 12;
const MAX_TAG_CHARS: usize = 12;

const THINKING_ENDS: &[&str] = &["</think>", "</thinking>", "</reasoning>", "</reason>", "[/think]", "◁/think▷", "</seed:think>", "<channel|>", "<|end_of_thought|>", "<|channel|>final<|message|>"];
const THINKING_STARTS: &[&str] = &["<think>", "<thinking>", "<reasoning>", "<reason>", "[think]", "◁think▷", "<seed:think>", "<|channel>thought", "<|channel|>analysis", "<|begin_of_thought|>"];

fn re(cell: &'static OnceLock<Regex>, pattern: &str) -> &'static Regex {
    cell.get_or_init(|| Regex::new(pattern).expect("pattern"))
}

/// A plain reply that is reasoning without any mark.
fn thinking_aloud() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    re(&R, r"(?i)^((thinking process|thinking|thoughts?|reasoning|analysis)\s*[:：]|let me|let's|okay,|ok,|hmm|the user|the image|this image|思考|嗯|好的|首先|用户)")   // i18n-exempt: model syntax
}

/// What follows the model's reasoning. Reasoning that never ended (the length limit) is no answer.
fn without_thinking(raw: &str) -> Result<String, ReplyError> {
    let mut text = raw.to_string();
    for end in THINKING_ENDS {
        if let Some(at) = rfind_ci(&text, end) { text = text[at + end.len()..].to_string(); }
    }
    let lower = text.to_lowercase();
    if THINKING_STARTS.iter().any(|s| lower.contains(s)) { return Err(ReplyError::Bad); }
    Ok(text)
}

/// The byte offset of the last case-insensitive (ASCII) occurrence of `needle` in `hay`.
fn rfind_ci(hay: &str, needle: &str) -> Option<usize> {
    let (h, n) = (hay.as_bytes(), needle.as_bytes());
    if n.len() > h.len() { return None; }
    (0..=h.len() - n.len()).rev().find(|&i| h[i..i + n.len()].eq_ignore_ascii_case(n) && hay.is_char_boundary(i))
}

fn is_space(c: char) -> bool { c.is_whitespace() }

/// User-perceived characters, roughly: joiners, variation selectors and combining marks belong to
/// the character before them, as do characters joined to it.
fn characters(s: &str) -> usize {
    let mut n = 0;
    let mut joined = false;
    for c in s.chars() {
        let u = c as u32;
        let attached = c == '\u{200D}' || (0xFE00..=0xFE0F).contains(&u) || (0x0300..=0x036F).contains(&u)
            || (0x1F3FB..=0x1F3FF).contains(&u) || (0xE0020..=0xE007F).contains(&u);
        if attached || joined { joined = c == '\u{200D}'; continue; }
        n += 1;
    }
    n
}

/// The tags in a model's reply.
pub fn parse_tags(raw: &str) -> Result<Vec<String>, ReplyError> {
    let mut text = without_thinking(raw)?.trim().to_string();
    if text.starts_with("```") {
        text = match text.find('\n') { Some(nl) => text[nl + 1..].to_string(), None => String::new() };
        let t = text.trim_end();
        text = t.strip_suffix("```").unwrap_or(t).trim().to_string();
    }
    let items: Vec<String>;
    let (a, b) = (text.find('['), text.rfind(']'));
    if a.is_some() || b.is_some() {
        let Some(a) = a else { return Err(ReplyError::Bad) };
        if matches!(b, Some(b) if b < a) { return Err(ReplyError::Bad); }
        let brackets = |s: &str| s.contains(['[', ']', '{', '}']);
        let before = text[..a].trim();
        let after = b.map_or("", |b| text[b + 1..].trim());
        let wrapped = before.starts_with('{') && !brackets(&before[1..]) && (after == "}" || b.is_none());
        if !wrapped && (brackets(before) || brackets(after)) { return Err(ReplyError::Bad); }
        items = list_items(&text[a + 1..b.unwrap_or(text.len())], b.is_none())?;
    } else {
        if thinking_aloud().is_match(&text) { return Err(ReplyError::Bad); }
        static LABEL: OnceLock<Regex> = OnceLock::new();
        text = re(&LABEL, "^[^,\u{FF0C}\u{3001};\u{FF1B}\n:\u{FF1A}{}\"]{1,24}[:\u{FF1A}]\\s*").replace(&text, "").into_owned();
        if text.contains(['{', '}', ':', '"']) { return Err(ReplyError::Bad); }
        items = text.split([',', '\u{FF0C}', '\u{3001}', ';', '\u{FF1B}', '\n', '#']).map(str::to_string).collect();
    }
    static FRAGMENT: OnceLock<Regex> = OnceLock::new();
    static PUNCTUATION: OnceLock<Regex> = OnceLock::new();
    let fragment = re(&FRAGMENT, r#"[{}\[\]<>:"\\`\x00-\x1F\x7F]"#);
    let punctuation = re(&PUNCTUATION, r"^[\x21-\x2F\x3A-\x40\x5B-\x60\x7B-\x7E\s]+$");
    let edge = |c: char| is_space(c) || "\"'\u{201C}\u{201D}[]()\u{FF08}\u{FF09}\u{3002}.".contains(c);
    let mut seen = HashSet::new();
    let mut result = Vec::new();
    let mut pieces = false;
    for item in items {
        let clean = item.trim_matches(edge).to_lowercase();
        if clean.is_empty() { continue; }
        if fragment.is_match(&clean) || punctuation.is_match(&clean) { pieces = true; continue; }
        if characters(&clean) <= MAX_TAG_CHARS && seen.insert(clean.clone()) { result.push(clean); }
        if result.len() == MAX_TAGS { break; }
    }
    if result.is_empty() { return Err(if pieces { ReplyError::Bad } else { ReplyError::None }); }
    Ok(result)
}

/// The entries between a list's brackets. `cut_off`: the reply stopped inside the list, and what it
/// was still writing is left out.
fn list_items(c: &str, cut_off: bool) -> Result<Vec<String>, ReplyError> {
    let c: Vec<char> = c.chars().collect();
    let closer = |ch: char| match ch { '"' => Some('"'), '\'' => Some('\''), '\u{201C}' => Some('\u{201D}'), '\u{2018}' => Some('\u{2019}'), _ => None };
    let mut items = Vec::new();
    let mut i = 0;
    while i < c.len() {
        if c[i] == ',' || is_space(c[i]) { i += 1; continue; }
        if let Some(close) = closer(c[i]) {
            let mut word = String::new();
            let mut j = i + 1;
            let mut closed = false;
            while j < c.len() {
                if c[j] == '\\' && j + 1 < c.len() {
                    let e = c[j + 1];
                    if e == 'n' || e == 't' || e == 'r' { word.push(' '); j += 2; }
                    else if e == 'u' {
                        let v = (j + 5 < c.len()).then(|| c[j + 2..j + 6].iter().collect::<String>()).and_then(|h| u32::from_str_radix(&h, 16).ok());
                        let Some(v) = v else { return Err(ReplyError::Bad) };
                        // (a lone surrogate half, as in Dart, becomes the replacement character)
                        word.push(char::from_u32(v).unwrap_or('\u{FFFD}'));
                        j += 6;
                    } else { word.push(e); j += 2; }
                    continue;
                }
                if c[j] == close {
                    // an apostrophe inside a word in single quotes (dog's) is not the end
                    let mut k = j + 1;
                    while k < c.len() && is_space(c[k]) { k += 1; }
                    if close != '\'' || k >= c.len() || c[k] == ',' { closed = true; j += 1; break; }
                }
                word.push(c[j]);
                j += 1;
            }
            if !closed { break; }
            items.push(word);
            i = j;
        } else {
            let j = c[i..].iter().position(|&x| x == ',').map_or(c.len(), |p| i + p);
            let word: String = c[i..j].iter().collect::<String>().trim().to_string();
            if word.contains(['[', ']', '{', '}']) { return Err(ReplyError::Bad); }
            let number = word.parse::<f64>().is_ok() && !word.chars().any(|x| x.is_alphabetic() && !"eE".contains(x));
            if !(cut_off && j == c.len()) && !number && !["null", "true", "false"].contains(&word.as_str()) { items.push(word); }
            i = j;
        }
    }
    Ok(items)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shared_cases() {
        let raw = include_str!("../../../scripts/checks/ai_tags/cases.json");
        let doc: serde_json::Value = serde_json::from_str(raw).unwrap();
        let mut failed = Vec::new();
        for case in doc["cases"].as_array().unwrap() {
            let reply = case["reply"].as_str().unwrap();
            let got = parse_tags(reply);
            let ok = match (case.get("tags"), case.get("error").and_then(|e| e.as_str())) {
                (Some(tags), _) => got.as_ref().ok().map(|g| serde_json::json!(g)) == Some(tags.clone()),
                (None, Some("bad")) => got == Err(ReplyError::Bad),
                (None, Some("none")) => got == Err(ReplyError::None),
                _ => false,
            };
            if !ok { failed.push(format!("{reply:?} -> {got:?}")); }
        }
        assert!(failed.is_empty(), "{}", failed.join("\n"));
    }
}
