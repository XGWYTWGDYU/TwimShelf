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
    /// The answer did not end by itself (token limit, a stray control token, a failed decode)
    /// or its list was cut off: what it holds is not a result.
    Incomplete,
}

/// Why the engine stopped writing (tl_llama's `finish`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Finish {
    /// The model ended its turn (an end-of-generation token).
    Ended,
    /// The token budget ran out.
    Length,
    /// A control token that is no end of generation (`<|turn>`): the model left its turn.
    Control,
    /// `llama_decode` failed midway.
    Decode,
}

/// A parsed reply with what the parser saw on the way.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Parsed {
    pub tags: Vec<String>,
    /// The list had no closing bracket: the reply stopped inside it.
    pub cut_off: bool,
    /// How often the most repeated entry occurred (after cleaning).
    pub most_repeated: usize,
    /// Entries left out for being longer than a tag may be.
    pub too_long: usize,
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
pub fn parse_tags(raw: &str) -> Result<Vec<String>, ReplyError> { parse_reply(raw).map(|p| p.tags) }

/// [`parse_tags`], with what was cut off, repeated or too long.
pub fn parse_reply(raw: &str) -> Result<Parsed, ReplyError> {
    let mut cut_off = false;
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
        cut_off = b.is_none();
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
    let mut counts: std::collections::HashMap<String, usize> = Default::default();
    let mut result = Vec::new();
    let (mut pieces, mut too_long) = (false, 0);
    for item in items {
        let clean = item.trim_matches(edge).to_lowercase();
        if clean.is_empty() { continue; }
        if fragment.is_match(&clean) || punctuation.is_match(&clean) { pieces = true; continue; }
        *counts.entry(joined_han(&clean)).or_default() += 1;
        if characters(&clean) > MAX_TAG_CHARS { too_long += 1; continue; }
        if result.len() < MAX_TAGS && seen.insert(clean.clone()) { result.push(clean); }
    }
    if result.is_empty() { return Err(if pieces { ReplyError::Bad } else { ReplyError::None }); }
    Ok(Parsed { tags: result, cut_off, most_repeated: counts.values().copied().max().unwrap_or(0), too_long })
}

fn han(c: char) -> bool {
    matches!(c as u32, 0x3400..=0x4DBF | 0x4E00..=0x9FFF | 0xF900..=0xFAFF | 0x20000..=0x3134F)
}

/// `label` without the spaces a model put between two Han characters ("藍色 衣服" is "藍色衣服");
/// a space next to other writing ("初音 miku", "3d 動畫") stays.
pub fn joined_han(label: &str) -> String {
    let c: Vec<char> = label.chars().collect();
    let mut out = String::new();
    for (i, &ch) in c.iter().enumerate() {
        if ch.is_whitespace() {
            let prev = out.chars().last();
            let next = c[i + 1..].iter().find(|x| !x.is_whitespace());
            if prev.is_some_and(han) && next.is_some_and(|&n| han(n)) { continue; }
        }
        out.push(ch);
    }
    out
}

/// A label no writing has: a broken character, or a Latin letter stuck to Han writing before a
/// space and more Han ("藍色t 隆": "T恤" with its second half gone). "T恤", "3D", "初音 Miku" and
/// one-character tags ("猫", "雨") are fine.
pub fn malformed(label: &str) -> bool {
    static R: OnceLock<Regex> = OnceLock::new();
    label.contains('\u{FFFD}') || re(&R, r"\p{Han}[A-Za-z]+\s+\p{Han}").is_match(label)
}

/// One entry this many times in one reply: the model was looping, not listing.
const LOOPING: usize = 3;

/// The tags of an on-device model's reply, stricter than [`parse_tags`]: only an answer the model
/// ended itself, whose list was not cut off and did not loop, is a result. Spaces between Han
/// characters go; malformed labels are left out (nothing left: [`ReplyError::Bad`]).
pub fn local_tags(raw: &str, finish: Finish) -> Result<Vec<String>, ReplyError> {
    if finish != Finish::Ended { return Err(ReplyError::Incomplete); }
    let parsed = parse_reply(raw)?;
    if parsed.cut_off { return Err(ReplyError::Incomplete); }
    if parsed.most_repeated >= LOOPING { return Err(ReplyError::Bad); }
    let mut seen = HashSet::new();
    let tags: Vec<String> = parsed.tags.iter().map(|t| joined_han(t)).filter(|t| !malformed(t) && seen.insert(t.clone())).collect();
    if tags.is_empty() { return Err(ReplyError::Bad); }
    Ok(tags)
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

#[cfg(test)]
mod local_reply {
    use super::{local_tags, parse_tags, Finish::*, ReplyError::*};

    // ---- what v2.0.0 accepts today (documenting the bug; parse_tags is unchanged) ----
    #[test]
    fn v2_accepts_the_observed_fragments() {
        assert_eq!(parse_tags("[\"興\",\"潔\",\"隆\",\"藍色t 隆\",\"藍色t 潔\",\"潔潔\",\"瞧\"]").unwrap().len(), 7);
        assert_eq!(parse_tags("[\"藍色T恤\",\"貓\",\"興").unwrap(), ["藍色t恤", "貓"]);
    }

    // ---- 1. complete JSON with bad words ----
    #[test]
    fn complete_json_drops_malformed_labels_keeps_the_rest() {
        let r = "```json\n[\"藍色t 隆\",\" 藍色t 潔\",\"雨\",\"貓\"]\n```";
        assert_eq!(local_tags(r, Ended).unwrap(), ["雨", "貓"]);
    }
    #[test]
    fn complete_json_of_nothing_but_malformed_labels_is_a_failure() {
        assert_eq!(local_tags("[\"藍色t 隆\",\"藍色t 潔\"]", Ended), Err(Bad));
        assert_eq!(local_tags("[\"\u{FFFD}色\"]", Ended), Err(Bad));
    }
    #[test]
    fn complete_json_single_characters_are_not_judged_by_shape() {
        // 興/潔 cannot be told from 猫/雨 by their shape: they are stored, and kept out of the
        // vocabulary by provenance instead (vocabulary tests)
        assert_eq!(local_tags("[\"興\",\"潔\",\"猫\"]", Ended).unwrap(), ["興", "潔", "猫"]);
    }

    // ---- 2. cut off ----
    #[test]
    fn a_reply_the_token_limit_ended_is_no_result() {
        // measured: tshirt.jpg, default prompt, contaminated vocabulary, stop=limit at 160
        let r = "```json\n[\n  \"藍色\",\n  \" 3D\",\n  \" 衣服\",\n  \" 潔\",\n  \" 簡約\",\n  \" 藍色 衣服\",\n  \" 藍色 芥\",\n  \" 藍色 窗戶\",\n  \" 藍色 藍色\",\n  \" 藍色 藍色 藍色\",\n  \" 藍色 ";
        assert!(parse_tags(r).is_ok(), "v2.0.0 takes this as a success");
        assert_eq!(local_tags(r, Length), Err(Incomplete));
    }
    #[test]
    fn a_list_without_its_closing_bracket_is_no_result_even_if_the_model_ended() {
        assert_eq!(local_tags("[\"貓\",\"雨\",\"沙", Ended), Err(Incomplete));
    }
    #[test]
    fn a_stray_control_token_or_a_failed_decode_is_no_result() {
        assert_eq!(local_tags("[\"貓\"]", Control), Err(Incomplete));
        assert_eq!(local_tags("[\"貓\"]", Decode), Err(Incomplete));
    }
    #[test]
    fn a_looping_reply_is_a_failure_even_when_it_ended() {
        // measured shape: "藍色 衣服" over and over; Han spaces are ignored when counting
        let r = "[\"藍色\",\" 藍色衣服\",\" 藍色 衣服\",\" 藍色 衣服\",\" 藍色 衣服\"]";
        assert_eq!(local_tags(r, Ended), Err(Bad));
        assert_eq!(local_tags("貓、 橘、 圓形、 橘、 橘、 橘", Ended), Err(Bad));
    }

    // ---- 3. reasoning that never ended ----
    #[test]
    fn unfinished_reasoning_is_no_result() {
        // Gemma 4's <|channel> is a user-defined token: it survives detokenizing (measured)
        let r = "<|channel>thought\nThe user wants me to act as an image annotator. I need to provide 5 to 10 short";
        assert_eq!(local_tags(r, Length), Err(Incomplete));
        assert_eq!(local_tags(r, Ended), Err(Bad));
        // had the marker been lost: the sentence pieces are too long, the short ones would remain
        let lost = "thought\n這張圖片顯示一件藍色的衣服，上面寫著3D，興、潔";
        assert_eq!(parse_tags(lost).unwrap(), ["thought", "上面寫著3d", "興", "潔"]);
        assert_eq!(local_tags(lost, Length), Err(Incomplete));
    }
    #[test]
    fn finished_reasoning_then_a_list_is_fine() {
        assert_eq!(local_tags("<|channel>thought\n貓<channel|>[\"貓\",\"雨\"]", Ended).unwrap(), ["貓", "雨"]);
    }

    // ---- valid tags stay ----
    #[test]
    fn single_character_and_mixed_tags_stay() {
        assert_eq!(local_tags("[\"猫\",\"雨\",\"T恤\",\"3D\"]", Ended).unwrap(), ["猫", "雨", "t恤", "3d"]);
        assert_eq!(local_tags("[\"初音 Miku\",\"3D 動畫\",\"C++\",\"😺\"]", Ended).unwrap(), ["初音 miku", "3d 動畫", "c++", "😺"]);
        assert_eq!(local_tags("貓、雨、T恤、3D", Ended).unwrap(), ["貓", "雨", "t恤", "3d"]);
    }
    #[test]
    fn spaces_between_han_characters_go() {
        // measured: the model writes " 藍色 衣服" with spaces between tokens
        assert_eq!(local_tags("```json\n[\"藍色 衣服\", \" 簡約 3D\"]\n```", Ended).unwrap(), ["藍色衣服", "簡約 3d"]);
    }
}
