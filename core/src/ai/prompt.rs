//! What a vision model is asked about a picture. The defaults are `core/prompts/<language>.txt`
//! (sections `[system]`, `[prompt]`, `[existing]`, `[vocabulary]`, `[context]`); the user can edit
//! them per model, and the app passes such an edited prompt along.
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::sync::OnceLock;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Prompt {
    pub system: String,
    pub prompt: String,
    /// `{text}`: the post's text.
    pub context: String,
    /// `{existing}`: the picture's tags.
    pub existing: String,
    /// `{tags}`: the library's tags.
    pub vocabulary: String,
}

fn bundled(lang: &str) -> &'static str {
    match lang {
        "en" => include_str!("../../prompts/en.txt"),
        "ja" => include_str!("../../prompts/ja.txt"),
        "zh-Hant" => include_str!("../../prompts/zh-Hant.txt"),
        _ => include_str!("../../prompts/zh-Hans.txt"),
    }
}

impl Prompt {
    /// The default prompt in `lang` (a catalog language; anything else: the current one).
    pub fn default_in(lang: &str) -> Prompt {
        let lang = if crate::i18n::LANGUAGES.contains(&lang) { lang } else { crate::i18n::language() };
        let mut p = Prompt { system: String::new(), prompt: String::new(), context: String::new(), existing: String::new(), vocabulary: String::new() };
        let mut section: Option<String> = None;
        let mut lines: Vec<&str> = Vec::new();
        let flush = |section: &Option<String>, lines: &mut Vec<&str>, p: &mut Prompt| {
            let value = lines.join("\n").trim().to_string();
            lines.clear();
            if value.is_empty() { return; }
            match section.as_deref() {
                Some("system") => p.system = value,
                Some("prompt") => p.prompt = value,
                Some("context") => p.context = value,
                Some("existing") => p.existing = value,
                Some("vocabulary") => p.vocabulary = value,
                _ => {}
            }
        };
        for line in bundled(lang).lines() {
            if line.starts_with('#') { continue; }
            let t = line.trim();
            if t.starts_with('[') && t.ends_with(']') && t.len() > 2 {
                flush(&section, &mut lines, &mut p);
                section = Some(t[1..t.len() - 1].to_string());
            } else {
                lines.push(line);
            }
        }
        flush(&section, &mut lines, &mut p);
        p
    }

    /// `self` with the fields `json` (a prompt as the apps store it, maybe partial) sets.
    fn merged(mut self, json: &str) -> Option<Prompt> {
        let v: serde_json::Value = serde_json::from_str(json).ok()?;
        let o = v.as_object()?;
        for (key, field) in [("system", &mut self.system), ("prompt", &mut self.prompt), ("context", &mut self.context), ("existing", &mut self.existing), ("vocabulary", &mut self.vocabulary)] {
            if let Some(t) = o.get(key).and_then(|x| x.as_str()) { *field = t.to_string(); }
        }
        Some(self)
    }

    /// The prompt model `id` tags with, from the settings every device of the account shares: its
    /// own (`ai.modelPrompt.<id>`); else a prompt set assigned to it before models had their own
    /// (`ai.modelPrompts`, `ai.prompts`); else the old common one (`ai.prompt`); else the default.
    pub fn for_model(setting: impl Fn(&str) -> Option<String>, id: &str) -> Prompt {
        let base = Prompt::default_in(crate::i18n::language());
        if let Some(p) = setting(&format!("ai.modelPrompt.{id}")).and_then(|j| base.clone().merged(&j)) { return p; }
        let assigned = setting("ai.modelPrompts").and_then(|j| serde_json::from_str::<serde_json::Value>(&j).ok())
            .and_then(|v| v.get(id).cloned()).filter(|v| !v.is_null());
        if let Some(set) = assigned {
            let sets: Vec<serde_json::Value> = setting("ai.prompts").and_then(|j| serde_json::from_str(&j).ok()).unwrap_or_default();
            if let Some(p) = sets.iter().find(|s| s.get("id") == Some(&set)).and_then(|s| base.clone().merged(&s["prompt"].to_string())) { return p; }
        }
        setting("ai.prompt").and_then(|j| base.clone().merged(&j)).unwrap_or(base)
    }

    /// The question about one picture: the prompt, then what is known about it.
    pub fn question(&self, existing: &[String], vocabulary: &[String], post_text: Option<&str>) -> String {
        let separator = crate::i18n::text("list.separator");
        let mut q = self.prompt.clone();
        if !existing.is_empty() { q += &format!("\n\n{}", self.existing.replace("{existing}", &existing.join(&separator))); }
        if !vocabulary.is_empty() { q += &format!("\n\n{}", self.vocabulary.replace("{tags}", &vocabulary.join(&separator))); }
        if let Some(clean) = clean_context(post_text) { q += &format!("\n\n{}", self.context.replace("{text}", &clean)); }
        q
    }
}

/// A post's text as context: without links and @mentions, at most 300 characters.
pub fn clean_context(text: Option<&str>) -> Option<String> {
    static LINK: OnceLock<Regex> = OnceLock::new();
    static MENTION: OnceLock<Regex> = OnceLock::new();
    let text = text?;
    let v = LINK.get_or_init(|| Regex::new(r"https?://\S+").unwrap()).replace_all(text, "");
    let v = MENTION.get_or_init(|| Regex::new(r"@[A-Za-z0-9_]{1,15}").unwrap()).replace_all(&v, "");
    let v = v.trim();
    if v.is_empty() { return None; }
    Some(if v.chars().count() > 300 { format!("{}\u{2026}", v.chars().take(300).collect::<String>()) } else { v.to_string() })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_language_has_every_section() {
        for lang in crate::i18n::LANGUAGES {
            let p = Prompt::default_in(lang);
            for (name, v) in [("system", &p.system), ("prompt", &p.prompt), ("context", &p.context), ("existing", &p.existing), ("vocabulary", &p.vocabulary)] {
                assert!(!v.is_empty(), "{lang}: no {name}");
            }
            assert!(p.context.contains("{text}") && p.existing.contains("{existing}") && p.vocabulary.contains("{tags}"), "{lang}");
        }
    }

    #[test]
    fn a_models_own_prompt_then_an_assigned_set_then_the_common_one() {
        let d = Prompt::default_in(crate::i18n::language());
        let none = |_: &str| None;
        assert_eq!(Prompt::for_model(none, "m"), d);
        let common = |k: &str| (k == "ai.prompt").then(|| r#"{"system":"c"}"#.to_string());
        assert_eq!(Prompt::for_model(common, "m").system, "c");
        let assigned = |k: &str| match k {
            "ai.modelPrompts" => Some(r#"{"m":"s1"}"#.into()),
            "ai.prompts" => Some(r#"[{"id":"s1","prompt":{"prompt":"set"}}]"#.into()),
            "ai.prompt" => Some(r#"{"system":"c"}"#.into()),
            _ => None,
        };
        let p = Prompt::for_model(assigned, "m");
        assert_eq!((p.prompt.as_str(), p.system.as_str()), ("set", d.system.as_str()));
        let own = |k: &str| (k == "ai.modelPrompt.m").then(|| r#"{"prompt":"own"}"#.to_string());
        assert_eq!(Prompt::for_model(own, "m").prompt, "own");
    }

    #[test]
    fn question_adds_what_is_known() {
        let p = Prompt::default_in("en");
        assert_eq!(p.question(&[], &[], None), p.prompt);
        let q = p.question(&["cat".into()], &["dog".into(), "sky".into()], Some("look @someone https://x.com/a nice"));
        assert!(q.contains("cat") && q.contains("dog、sky") && q.contains("look") && q.contains("nice") && !q.contains("https") && !q.contains("@someone"));
        assert_eq!(clean_context(Some("  @a https://b ")), None);
    }
}
