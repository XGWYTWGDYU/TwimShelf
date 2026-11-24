//! The search's words, minus-words, searched fields and tag origins: the SQL of
//! `Store::feed_filtered` agrees with the pure rule `rules::search_matches` on random libraries,
//! and worked examples (the ones in the search report) hold on a real library.
use proptest::prelude::*;
use tl_core::library::{FeedFilter, SearchFields};
use tl_core::model::{MediaKind, Origin, PostMeta, SearchScope};
use tl_core::rules::{origins_for, require_matches, search_matches, Review};
use tl_core::store::Store;

const WORDS: [&str; 6] = ["猫", "白墙", "cat", "dog", "al", "墙"];
const LABELS: [&str; 5] = ["猫", "小猫", "白墙", "cat", "墙纸"];
const TEXTS: [&str; 4] = ["今天的猫和白墙", "a Dog runs", "", "CAT 与 狗"];
const AUTHORS: [(&str, &str); 3] = [("Alice", "al"), ("小白", "xiaobai"), ("Bob", "bobcat")];

fn mid(m: usize) -> String { format!("{m:064}") }

/// Posts p0..p2 (text, author), media 0..4 spread over them, tags with origins 1 / 2 / 3.
fn library(posts: &[(usize, usize)], owner: &[usize], tags: &[(usize, usize, u8)]) -> Store {
    let s = Store::open(":memory:").unwrap();
    for (i, (t, a)) in posts.iter().enumerate() {
        s.upsert_post(&PostMeta { id: format!("p{i}"), text: Some(TEXTS[*t].into()).filter(|t: &String| !t.is_empty()),
            author_name: Some(AUTHORS[*a].0.into()), screen_name: Some(AUTHORS[*a].1.into()), ..Default::default() }).unwrap();
    }
    for (m, p) in owner.iter().enumerate() {
        s.add_media(&mid(m), &format!("p{p}"), m as i64, &MediaKind::Photo, &format!("blobs/00/{}.jpg", mid(m)), false).unwrap();
    }
    for (m, l, o) in tags {
        if o & 1 != 0 { s.tag_media(&mid(*m), LABELS[*l], Origin::USER).unwrap(); }
        if o & 2 != 0 { s.tag_media(&mid(*m), LABELS[*l], Origin::AI).unwrap(); }
    }
    s
}

fn scope_of(mask: u8) -> SearchScope { match mask { 1 => SearchScope::Mine, 2 => SearchScope::Ai, 4 => SearchScope::Common, _ => SearchScope::Both } }

proptest! {
    #![proptest_config(ProptestConfig::with_cases(400))]

    #[test]
    fn sql_search_agrees_with_rule(
        posts in proptest::collection::vec((0..4usize, 0..3usize), 3),
        owner in proptest::collection::vec(0..3usize, 1..5),
        tags in proptest::collection::vec((0..5usize, 0..5usize, 1..4u8), 0..10),
        terms in proptest::collection::vec(0..6usize, 0..3),
        exclude in proptest::collection::vec(0..6usize, 0..3),
        fields in (any::<bool>(), any::<bool>(), any::<bool>()),
        scope_mask in prop_oneof![Just(1u8), Just(2), Just(3), Just(4)],
        minus in (any::<bool>(), any::<bool>(), any::<bool>()),
        require in proptest::option::of((any::<bool>(), any::<bool>(), any::<bool>())),
    ) {
        let n = owner.len();
        let tags: Vec<_> = tags.into_iter().filter(|(m, _, _)| *m < n).collect();
        let s = library(&posts, &owner, &tags);
        let terms: Vec<String> = terms.iter().map(|i| WORDS[*i].to_string()).collect();
        let exclude: Vec<String> = exclude.iter().map(|i| WORDS[*i].to_string()).collect();
        let origins = origins_for(scope_mask, minus.0, minus.1, minus.2);
        // label sets as the non-semantic search builds them: every live label containing the word
        let labels = s.all_labels().unwrap();
        let sets: Vec<Vec<String>> = terms.iter().map(|t| labels.iter().filter(|l| l.contains(t.as_str())).cloned().collect()).collect();
        let f = FeedFilter { exclude_terms: exclude.clone(), origins: Some(origins.clone()),
            require: require.map(|r| SearchFields { tags: r.0, text: r.1, author: r.2 }), ..Default::default() };
        let sf = SearchFields { tags: fields.0, text: fields.1, author: fields.2 };
        let mut got: Vec<String> = s.feed_filtered(&sets, &terms, scope_of(scope_mask), sf, &f).unwrap().into_iter().map(|i| i.media_id).collect();
        got.sort();
        let mut want = vec![];
        for (m, p) in owner.iter().enumerate() {
            let mt = s.media_tags(&mid(m)).unwrap();
            let mt: Vec<(&str, u8)> = mt.iter().map(|(l, o)| (l.as_str(), *o)).collect();
            let (t, a) = posts[*p];
            let tw: Vec<&str> = terms.iter().map(|x| x.as_str()).collect();
            let ew: Vec<&str> = exclude.iter().map(|x| x.as_str()).collect();
            let au = [AUTHORS[a].0, AUTHORS[a].1];
            if search_matches(fields, &origins, &mt, TEXTS[t], &au, &tw, &ew)
                && require.map_or(true, |r| require_matches(r, &origins, &mt, TEXTS[t], &au)) { want.push(mid(m)); }
        }
        want.sort();
        prop_assert_eq!(got, want);
    }
}

#[test]
fn origins_follow_scope_and_minus_words() {
    assert_eq!(origins_for(3, false, false, false), vec![1, 2, 3]);
    assert_eq!(origins_for(3, true, false, false), vec![2], "-我的: only tags the AI gave alone");
    assert_eq!(origins_for(3, false, true, false), vec![1], "-AI: only tags I gave alone");
    assert_eq!(origins_for(3, false, false, true), vec![1, 2], "-共同");
    assert_eq!(origins_for(1, false, false, false), vec![1, 3], "我的 includes endorsed");
    assert_eq!(origins_for(4, false, false, false), vec![3], "共同");
    assert_eq!(origins_for(2, false, true, false), Vec::<u8>::new(), "AI -AI: no tag at all");
}

/// The worked examples of the search report.
#[test]
fn report_examples() {
    // m0: post by Alice "今天的猫和白墙", tags 猫 (mine) · m1: post by 小白 (@xiaobai) "a Dog runs", tag 白墙 (AI)
    // m2: post by Bob (@bobcat) "CAT 与 狗", tag cat (both) · m3: Alice again, no text, tag 墙纸 (AI)
    let s = library(&[(0, 0), (1, 1), (3, 2), (2, 0)], &[0, 1, 2, 3], &[(0, 0, 1), (1, 2, 2), (2, 3, 3), (3, 4, 2)]);
    let run = |terms: &[&str], fields: (bool, bool, bool), f: FeedFilter| -> Vec<usize> {
        let labels = s.all_labels().unwrap();
        let terms: Vec<String> = terms.iter().map(|t| t.to_string()).collect();
        let sets: Vec<Vec<String>> = terms.iter().map(|t| labels.iter().filter(|l| l.contains(t.as_str())).cloned().collect()).collect();
        let mut v: Vec<usize> = s.feed_filtered(&sets, &terms, SearchScope::Both, SearchFields { tags: fields.0, text: fields.1, author: fields.2 }, &f).unwrap()
            .into_iter().map(|i| (0..4).find(|m| mid(*m) == i.media_id).unwrap()).collect();
        v.sort(); v
    };
    let all = (true, true, true);
    let ex = |w: &[&str]| FeedFilter { exclude_terms: w.iter().map(|x| x.to_string()).collect(), ..Default::default() };
    // "用户 al": only the author field, never the text
    assert_eq!(run(&["al"], (false, false, true), FeedFilter::default()), vec![0, 3]);
    // "猫": tags, text and authors (cat ≠ 猫)
    assert_eq!(run(&["猫"], all, FeedFilter::default()), vec![0]);
    // "cat": tag cat on m2, author @bobcat on m2, "CAT" in m2's text
    assert_eq!(run(&["cat"], all, FeedFilter::default()), vec![2]);
    // "墙 -猫": 墙 in m0 (text 白墙), m1 (tag 白墙), m3 (tag 墙纸); m0 also has 猫 → out
    assert_eq!(run(&["墙"], all, ex(&["猫"])), vec![1, 3]);
    // "-al" alone: everything without "al" anywhere searched (m0 and m3 are by @al; "alice" too)
    assert_eq!(run(&[], all, ex(&["al"])), vec![1, 2]);
    // "墙 -用户": text and tags only
    assert_eq!(run(&["墙"], (true, true, false), FeedFilter::default()), vec![0, 1, 3]);
    // "-用户 al": al no longer matches the authors; nothing else contains al
    assert_eq!(run(&["al"], (true, true, false), FeedFilter::default()), Vec::<usize>::new());
    // "墙 -AI": only tags I gave (or text): m0 by text; m1, m3 have 墙 only in AI tags
    assert_eq!(run(&["墙"], all, FeedFilter { origins: Some(origins_for(3, false, true, false)), ..Default::default() }), vec![0]);
    // "标签 墙 -我的" (tags only, AI tags): m1 (白墙 AI), m3 (墙纸 AI)
    assert_eq!(run(&["墙"], (true, false, false), FeedFilter { origins: Some(origins_for(3, true, false, false)), ..Default::default() }), vec![1, 3]);
}

#[test]
fn excluded_folders_recent_and_loose() {
    let s = library(&[(0, 0), (1, 1), (2, 2)], &[0, 1, 2], &[]);
    s.create_folder("旅行").unwrap();
    s.add_to_folder("旅行", &[mid(0), mid(2)]).unwrap();
    let ids = |f: FeedFilter| -> Vec<String> { let mut v: Vec<String> = s.feed_filtered(&[], &[], SearchScope::Both, Default::default(), &f).unwrap().into_iter().map(|i| i.media_id).collect(); v.sort(); v };
    assert_eq!(ids(FeedFilter { exclude_folders: vec!["旅行".into()], ..Default::default() }), vec![mid(1)]);
    // in a folder and not in it: nothing
    assert!(ids(FeedFilter { folder: Some("旅行".into()), exclude_folders: vec!["旅行".into()], ..Default::default() }).is_empty());
    assert_eq!(ids(FeedFilter { exclude_loose: true, ..Default::default() }).len(), 3, "no loose media here");
    assert_eq!(ids(FeedFilter { exclude_recent: true, ..Default::default() }).len(), 3, "nothing recent here");
}

/// Conditions without any word to find: each capsule alone gives everything it stands for, as
/// the apps send it (`TokenQuery` on every platform): 标签 / 贴文 / 用户 and the tag origins
/// (我的 / AI / 共同 / 全部, with or without a minus) through `require`, the rest through the
/// filters that never needed a word.
#[test]
fn conditions_alone() {
    // m0 p0 Alice "今天的猫和白墙", 猫 mine · m1 p1 小白 "a Dog runs", video, 白墙 AI
    // m2 p2 Bob "CAT 与 狗", cat by both (common) · m3 p3 Alice, no text, no tag, damaged, in 旅行
    // m4 loose, no text, no author, no tag, from the photo library · p1 is recently added
    let s = Store::open(":memory:").unwrap();
    for (id, text, author) in [("p0", Some("今天的猫和白墙"), Some(("Alice", "al"))), ("p1", Some("a Dog runs"), Some(("小白", "xiaobai"))),
        ("p2", Some("CAT 与 狗"), Some(("Bob", "bobcat"))), ("p3", None, Some(("Alice", "al"))), ("loose:1", None, None)] {
        s.upsert_post(&PostMeta { id: id.into(), text: text.map(String::from), author_name: author.map(|a| a.0.into()), screen_name: author.map(|a| a.1.into()), ..Default::default() }).unwrap();
    }
    for (m, p, k) in [(0, "p0", MediaKind::Photo), (1, "p1", MediaKind::Video), (2, "p2", MediaKind::Photo), (3, "p3", MediaKind::Photo), (4, "loose:1", MediaKind::Photo)] {
        s.add_media(&mid(m), p, 0, &k, &format!("blobs/00/{}.jpg", mid(m)), false).unwrap();
    }
    s.tag_media(&mid(0), "猫", Origin::USER).unwrap();
    s.tag_media(&mid(1), "白墙", Origin::AI).unwrap();
    s.tag_media(&mid(2), "cat", Origin::AI).unwrap();
    s.tag_media(&mid(2), "cat", Origin::USER).unwrap();
    s.set_bad(&mid(3), Some("missing")).unwrap();
    s.create_folder("旅行").unwrap();
    s.add_to_folder("旅行", &[mid(3)]).unwrap();
    s.mark_album(&mid(4)).unwrap();
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as u64;
    s.mark_recent("p1", now).unwrap();

    let run = |scope: SearchScope, f: FeedFilter| -> Vec<usize> {
        let mut v: Vec<usize> = s.feed_filtered(&[], &[], scope, SearchFields::default(), &f).unwrap()
            .into_iter().map(|i| (0..5).find(|m| mid(*m) == i.media_id).unwrap()).collect();
        v.sort(); v
    };
    let req = |tags, text, author| FeedFilter { require: Some(SearchFields { tags, text, author }), ..Default::default() };
    let tags = || req(true, false, false);
    let origins = |o: Vec<u8>| FeedFilter { origins: Some(o), ..tags() };
    let both = SearchScope::Both;
    // fields
    assert_eq!(run(both, tags()), vec![0, 1, 2], "标签: media with a tag");
    assert_eq!(run(both, req(false, true, false)), vec![0, 1, 2], "贴文: posts with text");
    assert_eq!(run(both, req(false, false, true)), vec![0, 1, 2, 3], "用户: posts with an author (not loose media)");
    assert_eq!(run(both, req(false, true, true)), vec![0, 1, 2, 3], "贴文 用户: either");
    assert_eq!(run(both, req(false, false, false)), Vec::<usize>::new(), "标签 -标签: nowhere to look");
    // tag origins
    assert_eq!(run(SearchScope::Mine, tags()), vec![0, 2], "我的: a tag I added or approved");
    assert_eq!(run(SearchScope::Ai, tags()), vec![1, 2], "AI: a tag the AI gave");
    assert_eq!(run(SearchScope::Common, tags()), vec![2], "共同: a tag both of us gave");
    assert_eq!(run(both, tags()), vec![0, 1, 2], "全部: a tag of either");
    assert_eq!(run(both, origins(origins_for(3, true, false, false))), vec![1], "-我的: a tag only the AI gave");
    assert_eq!(run(both, origins(origins_for(3, false, true, false))), vec![0], "-AI: a tag only I gave");
    assert_eq!(run(both, origins(origins_for(3, false, false, true))), vec![0, 1], "-共同: a tag only one of us gave");
    assert_eq!(run(both, origins(origins_for(2, false, true, false))), Vec::<usize>::new(), "AI -AI: no tag counts");
    assert_eq!(run(SearchScope::Mine, req(false, true, false)), vec![0, 1, 2], "贴文 我的: the field decides (as with words)");
    // filters that never needed a word
    let all = vec![0, 1, 2, 3, 4];
    assert_eq!(run(both, FeedFilter::default()), all, "-标签 / -贴文 / -用户 alone narrow nothing");
    assert_eq!(run(both, FeedFilter { kind: Some(MediaKind::Video), ..Default::default() }), vec![1], "视频 (and -照片)");
    assert_eq!(run(both, FeedFilter { kind: Some(MediaKind::Photo), ..Default::default() }), vec![0, 2, 3, 4], "照片 (and -视频)");
    assert_eq!(run(both, FeedFilter { folder: Some("旅行".into()), ..Default::default() }), vec![3], "文件夹 旅行");
    assert_eq!(run(both, FeedFilter { exclude_folders: vec!["旅行".into()], ..Default::default() }), vec![0, 1, 2, 4], "-文件夹 旅行");
    assert_eq!(run(both, FeedFilter { recent_only: true, ..Default::default() }), vec![1], "最近");
    assert_eq!(run(both, FeedFilter { exclude_recent: true, ..Default::default() }), vec![0, 2, 3, 4], "-最近");
    assert_eq!(run(both, FeedFilter { loose_only: true, ..Default::default() }), vec![4], "外部导入");
    assert_eq!(run(both, FeedFilter { exclude_loose: true, ..Default::default() }), vec![0, 1, 2, 3], "-外部导入");
    assert_eq!(run(both, FeedFilter { album_only: true, ..Default::default() }), vec![4], "相册");
    assert_eq!(run(both, FeedFilter { review: Review::Reviewed, ..Default::default() }), vec![0, 2], "已认可");
    assert_eq!(run(both, FeedFilter { review: Review::Unreviewed, ..Default::default() }), vec![1, 3, 4], "未认可");
    assert_eq!(run(both, FeedFilter { bad_only: true, ..Default::default() }), vec![3], "损坏");
    // together: every condition holds
    assert_eq!(run(SearchScope::Common, FeedFilter { kind: Some(MediaKind::Photo), ..tags() }), vec![2], "共同 照片");
    assert_eq!(run(SearchScope::Ai, FeedFilter { kind: Some(MediaKind::Video), ..tags() }), vec![1], "AI 视频");
}
