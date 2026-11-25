//! ModelScope (modelscope.cn), the other place models come from: it mirrors many of Hugging Face's
//! repos under the same names, and is the one reachable in mainland China. Its answers are turned
//! into the shapes the rest of the core reads from Hugging Face's API, so the store, the checks
//! and the downloads stay one.
//!
//! Its search answers say nothing of a repo's files: whether a GGUF repo has a projector, or what
//! architecture an MLX repo is, is known only in the repo's detail (marked `files_unknown`).
use anyhow::Context;
use serde_json::{json, Value};

pub const BASE: &str = "https://modelscope.cn";

/// Hugging Face's branch name, which the catalog's downloads follow, is `master` there.
fn revision(r: &str) -> &str { if r == "main" { "master" } else { r } }

pub fn search_url() -> String { format!("{BASE}/api/v1/dolphin/models") }
pub fn info_url(repo: &str) -> String { format!("{BASE}/api/v1/models/{repo}") }
pub fn files_url(repo: &str, rev: &str) -> String { format!("{BASE}/api/v1/models/{repo}/repo/files?Revision={}&Recursive=true", revision(rev)) }
pub fn file_url(repo: &str, rev: &str, file: &str) -> String { format!("{BASE}/models/{repo}/resolve/{}/{file}", revision(rev)) }
pub fn page_url(repo: &str) -> String { format!("{BASE}/models/{repo}") }

/// A search's request: `format`'s library, sorted by downloads, one page.
pub fn search_body(format: &str, text: &str, page: u32, size: u32) -> Value {
    json!({
        "PageSize": size, "PageNumber": page, "SortBy": "DownloadsCount", "Target": "", "Name": text,
        "Criterion": [{ "category": "libraries", "predicate": "contains", "values": [if format == "gguf" { "gguf" } else { "mlx" }] }],
    })
}

fn data(v: &Value) -> anyhow::Result<&Value> {
    if v["Success"].as_bool() != Some(true) { anyhow::bail!("ModelScope: {}", v["Message"].as_str().unwrap_or("no answer")); }
    Ok(&v["Data"])
}

/// A search's answer: its repos in Hugging Face's shape, and whether a further page exists.
pub fn search_results(format: &str, v: &Value, page: u32, size: u32) -> anyhow::Result<(Vec<Value>, bool)> {
    let m = &data(v)?["Model"];
    let list = m["Models"].as_array().cloned().unwrap_or_default();
    let more = m["TotalCount"].as_u64().map_or(false, |t| u64::from(page) * u64::from(size) < t);
    Ok((list.iter().map(|x| shape(format, x, None)).collect(), more))
}

/// A count it gives as a number or a string; 0 is how it says it does not know.
fn number(v: &Value) -> Option<u64> { v.as_u64().or_else(|| v.as_str().and_then(|s| s.parse().ok())).filter(|n| *n > 0) }

/// One repo (a search result, or a repo's own answer with its files) as Hugging Face's.
fn shape(format: &str, d: &Value, files: Option<&[Value]>) -> Value {
    let repo = format!("{}/{}", d["Path"].as_str().unwrap_or_default(), d["Name"].as_str().unwrap_or_default());
    let mut tags = vec![json!(format)];
    if let Some(l) = d["License"].as_str().filter(|l| !l.is_empty()) { tags.push(json!(format!("license:{l}"))); }
    let infos = &d["ModelInfos"];
    let mut m = json!({
        "id": repo, "tags": tags,
        // a repo whose files have to be asked for
        "gated": d["IsAccessible"].as_i64().map_or(Value::Bool(false), |a| if a == 1 { Value::Bool(false) } else { json!("manual") }),
        "downloads": d["Downloads"].as_u64().unwrap_or(0), "likes": d["Stars"].as_u64().unwrap_or(0),
    });
    if format == "gguf" {
        m["gguf"] = json!({ "architecture": infos["gguf"]["architecture"], "total": number(&infos["gguf"]["model_size"]) });
    } else {
        m["safetensors"] = json!({ "total": number(&infos["safetensor"]["model_size"]) });
    }
    match files {
        Some(f) => m["siblings"] = Value::Array(f.iter().filter(|f| f["Type"].as_str() == Some("blob")).map(|f| json!({ "rfilename": f["Path"] })).collect()),
        None => m["files_unknown"] = json!(true),
    }
    m
}

/// A repo's own answer and its file list as Hugging Face's model answer. `sha` is its latest
/// commit, which its files can be pinned to; `config` (MLX) is its config.json.
pub fn model(format: &str, info: &Value, files: &Value, config: Option<Value>) -> anyhow::Result<Value> {
    let d = data(info)?;
    let f = data(files)?;
    let list = f["Files"].as_array().cloned().unwrap_or_default();
    let short = f["LatestCommitter"]["ShortId"].as_str().filter(|s| !s.is_empty());
    let sha = list.iter().filter_map(|x| x["Revision"].as_str()).filter(|r| r.len() == 40)
        .find(|r| short.map_or(false, |s| r.starts_with(s)))
        .or_else(|| list.iter().max_by_key(|x| x["CommittedDate"].as_u64().unwrap_or(0)).and_then(|x| x["Revision"].as_str()));
    let mut m = shape(format, d, Some(&list));
    m["sha"] = json!(sha);
    if let Some(c) = config { m["config"] = c; }
    Ok(m)
}

/// A file list as Hugging Face's tree: `[{type, path, size, lfs: {oid}}]`.
pub fn tree(files: &Value) -> anyhow::Result<Value> {
    let list = data(files)?["Files"].as_array().context("ModelScope: no files")?;
    Ok(Value::Array(list.iter().map(|f| {
        let file = f["Type"].as_str() == Some("blob");
        let mut e = json!({ "type": if file { "file" } else { "directory" }, "path": f["Path"].as_str().unwrap_or_default(), "size": f["Size"].as_u64().unwrap_or(0) });
        if let Some(s) = f["Sha256"].as_str().filter(|s| s.len() == 64) { e["lfs"] = json!({ "oid": s }); }
        e
    }).collect()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn files() -> Value {
        json!({ "Success": true, "Data": { "LatestCommitter": { "ShortId": "20448608" }, "Files": [
            { "Type": "blob", "Path": "m-Q4_K_M.gguf", "Size": 10, "Sha256": "a".repeat(64), "Revision": "1".repeat(40), "CommittedDate": 2 },
            { "Type": "blob", "Path": "mmproj-m-Q8_0.gguf", "Size": 5, "Sha256": "b".repeat(64), "Revision": format!("20448608{}", "0".repeat(32)), "CommittedDate": 1 },
            { "Type": "tree", "Path": "extra", "Size": 0 },
        ] } })
    }

    #[test]
    fn a_repo_reads_as_hugging_faces() {
        let info = json!({ "Success": true, "Data": { "Path": "o", "Name": "m-GGUF", "License": "apache-2.0", "Downloads": 7, "Stars": 1, "IsAccessible": 1,
            "ModelInfos": { "gguf": { "architecture": "qwen2vl", "model_size": "3085938688" } } } });
        let m = model("gguf", &info, &files(), None).unwrap();
        assert_eq!(m["id"], "o/m-GGUF");
        assert_eq!(m["gated"], false);
        assert_eq!(m["gguf"]["architecture"], "qwen2vl");
        assert_eq!(m["gguf"]["total"], 3085938688u64);
        // the latest commit, by its short id
        assert_eq!(m["sha"], format!("20448608{}", "0".repeat(32)));
        assert_eq!(m["siblings"].as_array().unwrap().len(), 2);
        assert!(m["tags"].as_array().unwrap().contains(&json!("license:apache-2.0")));
        assert!(m.get("files_unknown").is_none());
    }

    #[test]
    fn files_read_as_a_tree() {
        let t = tree(&files()).unwrap();
        assert_eq!(t[0]["type"], "file");
        assert_eq!(t[0]["lfs"]["oid"], "a".repeat(64));
        assert_eq!(t[2]["type"], "directory");
    }

    #[test]
    fn search_results_say_their_files_are_unknown() {
        let v = json!({ "Success": true, "Data": { "Model": { "TotalCount": 3, "Models": [
            { "Path": "o", "Name": "a", "ModelInfos": { "gguf": { "architecture": "gemma3", "model_size": 4 } } }] } } });
        let (list, more) = search_results("gguf", &v, 1, 2).unwrap();
        assert!(more);
        assert_eq!(list[0]["files_unknown"], true);
        assert!(!search_results("gguf", &v, 2, 2).unwrap().1);
        let unknown = json!({ "Success": true, "Data": { "Model": { "TotalCount": 1, "Models": [{ "Path": "o", "Name": "b", "ModelInfos": { "safetensor": { "model_size": 0 } } }] } } });
        assert!(search_results("mlx", &unknown, 1, 2).unwrap().0[0]["safetensors"]["total"].is_null());
        assert!(search_results("gguf", &json!({ "Success": false, "Message": "x" }), 1, 2).is_err());
    }

    #[test]
    fn the_main_branch_is_master() {
        assert_eq!(file_url("o/m", "main", "f.gguf"), "https://modelscope.cn/models/o/m/resolve/master/f.gguf");
        assert!(files_url("o/m", &"c".repeat(40)).contains(&format!("Revision={}", "c".repeat(40))));
    }
}
