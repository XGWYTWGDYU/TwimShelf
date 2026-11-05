//! Text the core hands to the apps (errors, import, export and sync reports) in the app's
//! language. Messages live in `core/messages.json` by key, one value per language; code
//! names the key (`tr!("import.cancelled")`, `tr!("import.unsupported_ext", ext = e)`), never the
//! text. Placeholders are `{name}`. The apps call `tl_set_language` at launch; until then (and in
//! the core's own tests) the language is Simplified Chinese, the language the app was written in.
use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Mutex, OnceLock};

/// The languages of the catalog, as the apps name them.
pub const LANGUAGES: [&str; 4] = ["zh-Hans", "en", "zh-Hant", "ja"];
const ENGLISH: usize = 1;

static CURRENT: AtomicUsize = AtomicUsize::new(0);

type Table = HashMap<String, HashMap<String, String>>;

fn table() -> &'static Table {
    static T: OnceLock<Table> = OnceLock::new();
    T.get_or_init(|| serde_json::from_str(include_str!("../messages.json")).expect("core/messages.json is valid"))
}

/// The catalog language for a language tag: an exact match, then by family (a script decides,
/// so zh-Hans-TW is Simplified; without one zh-TW / zh-HK / zh-MO are Traditional, other zh
/// Simplified), English for anything else.
pub fn resolve(tag: &str) -> usize {
    let t = tag.trim().replace('_', "-");
    if let Some(i) = LANGUAGES.iter().position(|l| l.eq_ignore_ascii_case(&t)) { return i; }
    let lower = t.to_ascii_lowercase();
    if lower.starts_with("zh") {
        let parts: Vec<&str> = lower.split('-').skip(1).collect();
        let traditional = if parts.contains(&"hans") { false } else { ["hant", "tw", "hk", "mo"].iter().any(|m| parts.contains(m)) };
        return if traditional { 2 } else { 0 };
    }
    if lower.starts_with("ja") { return 3; }
    ENGLISH
}

pub fn set_language(tag: &str) {
    CURRENT.store(resolve(tag), Ordering::Relaxed);
}
pub fn language() -> &'static str { LANGUAGES[CURRENT.load(Ordering::Relaxed)] }

/// What `{app}` stands for in a message: builds of the app have different names.
static APP_NAME: Mutex<Option<String>> = Mutex::new(None);
pub fn set_app_name(name: &str) { *APP_NAME.lock().unwrap_or_else(|e| e.into_inner()) = Some(name.to_string()); }

/// The message `key` in `lang` (falling back to English, then to the key itself).
pub fn text_in(lang: &str, key: &str) -> String {
    let Some(entry) = table().get(key) else { return key.to_string() };
    let text = entry.get(lang).or_else(|| entry.get(LANGUAGES[ENGLISH])).cloned().unwrap_or_else(|| key.to_string());
    if !text.contains("{app}") { return text; }
    let name = APP_NAME.lock().unwrap_or_else(|e| e.into_inner());
    text.replace("{app}", name.as_deref().unwrap_or("TwimShelf"))
}

/// The message `key` in the current language.
pub fn text(key: &str) -> String { text_in(language(), key) }

/// The message with its `{name}` placeholders filled.
pub fn fill(key: &str, args: &[(&str, String)]) -> String { fill_in(language(), key, args) }

pub fn fill_in(lang: &str, key: &str, args: &[(&str, String)]) -> String {
    let mut s = text_in(lang, key);
    for (name, value) in args { s = s.replace(&format!("{{{name}}}"), value); }
    s
}

/// Every key with its languages (for the catalog check).
pub fn keys() -> impl Iterator<Item = (&'static String, &'static HashMap<String, String>)> { table().iter() }

/// `tr!("key")` or `tr!("key", name = value, …)`: the message in the current language.
#[macro_export]
macro_rules! tr {
    ($key:expr) => { $crate::i18n::text($key) };
    ($key:expr, $($name:ident = $value:expr),+ $(,)?) => {
        $crate::i18n::fill($key, &[$((stringify!($name), ($value).to_string())),+])
    };
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_message_has_every_language_and_the_same_placeholders() {
        let ph = regex::Regex::new(r"\{[a-z_0-9]+\}").unwrap();
        for (key, langs) in keys() {
            let base: std::collections::BTreeSet<&str> = ph.find_iter(&langs["en"]).map(|m| m.as_str()).collect();
            for l in LANGUAGES {
                let v = langs.get(l).unwrap_or_else(|| panic!("{key}: no {l}"));
                assert!(!v.trim().is_empty(), "{key}: empty {l}");
                let got: std::collections::BTreeSet<&str> = ph.find_iter(v).map(|m| m.as_str()).collect();
                assert_eq!(got, base, "{key}: {l} has other placeholders than en");
            }
        }
    }

    #[test]
    fn language_tags_resolve_by_family() {
        assert_eq!(LANGUAGES[resolve("zh-Hans-CN")], "zh-Hans");
        assert_eq!(LANGUAGES[resolve("zh_TW")], "zh-Hant");
        assert_eq!(LANGUAGES[resolve("zh-Hant-HK")], "zh-Hant");
        assert_eq!(LANGUAGES[resolve("zh-Hans-TW")], "zh-Hans");
        assert_eq!(LANGUAGES[resolve("zh-Hant-CN")], "zh-Hant");
        assert_eq!(LANGUAGES[resolve("ja-JP")], "ja");
        assert_eq!(LANGUAGES[resolve("de")], "en");
        assert_eq!(LANGUAGES[resolve("en")], "en");
    }

    #[test]
    fn placeholders_fill_and_unknown_keys_show_themselves() {
        assert_eq!(fill_in("en", "no.such.key", &[]), "no.such.key");
    }
}
