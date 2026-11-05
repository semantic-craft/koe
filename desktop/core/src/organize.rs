use crate::{Recording, minutes};
use anyhow::{Result, bail};
use chrono::SecondsFormat;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

pub fn generate_minutes_for_recording(
    recording: &Recording,
    instruction: &str,
    existing: Option<&Value>,
) -> Result<Value> {
    let text = recording.transcript.trim();
    if text.is_empty() {
        bail!("当前录音尚无转写正文，无法生成纪要");
    }
    let sources: Vec<String> = text
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(str::to_owned)
        .collect();
    if sources.is_empty() {
        bail!("当前录音尚无有效转写段落，无法生成纪要");
    }
    let source_refs: Vec<String> = (1..=sources.len()).map(|i| format!("S{i}")).collect();
    let first_ref = vec!["S1".to_owned()];
    let overview = if sources.len() == 1 {
        sources[0].clone()
    } else {
        format!("共整理 {} 段发言，核心内容：{}", sources.len(), sources[0])
    };
    let points: Vec<Value> = sources
        .iter()
        .enumerate()
        .map(|(idx, line)| {
            json!({
                "text": line,
                "sources": [format!("S{}", idx + 1)],
            })
        })
        .collect();
    let branches: Vec<Value> = sources
        .iter()
        .enumerate()
        .take(4)
        .map(|(idx, line)| {
            let (speaker, detail) = line
                .split_once('：')
                .map(|(s, d)| (s.trim(), d.trim()))
                .filter(|(s, d)| !s.is_empty() && !d.is_empty())
                .unwrap_or(("要点", line.as_str()));
            json!({
                "text": speaker,
                "detail": detail,
                "sources": [format!("S{}", idx + 1)],
            })
        })
        .collect();
    let mut decisions = Vec::new();
    let mut actions = Vec::new();
    let mut questions = Vec::new();
    for (idx, line) in sources.iter().enumerate() {
        let sref = format!("S{}", idx + 1);
        let (speaker, content) = line
            .split_once('：')
            .map(|(s, d)| (s.trim(), d.trim()))
            .filter(|(s, d)| !s.is_empty() && !d.is_empty())
            .unwrap_or(("待定", line.as_str()));
        if line.contains("确认") || line.contains("同意") || line.contains("决定") {
            decisions.push(json!({
                "text": content,
                "sources": [sref.clone()],
            }));
        }
        if line.contains("完成")
            || line.contains("交付")
            || line.contains("联调")
            || line.contains("跟进")
        {
            actions.push(json!({
                "text": content,
                "owner": speaker,
                "due": "按计划推进",
                "sources": [sref.clone()],
            }));
        }
        if line.contains('？') || line.contains('?') || line.contains("是否") {
            questions.push(json!({
                "text": content,
                "sources": [sref],
            }));
        }
    }
    if actions.is_empty() {
        actions.push(json!({
            "text": sources[0],
            "owner": "待认领",
            "due": "待确认",
            "sources": first_ref,
        }));
    }
    let body = json!({
        "schemaVersion": 2,
        "title": recording.display_name,
        "overview": overview,
        "topics": [{
            "text": if instruction.trim().is_empty() { "核心议题" } else { instruction.trim() },
            "summary": overview,
            "sources": source_refs,
            "points": points,
            "fishbone": {
                "question": recording.display_name,
                "branches": branches,
            }
        }],
        "decisions": decisions,
        "actions": actions,
        "questions": questions,
        "terms": [],
        "reviewItems": ["核对人名与时间节点"],
    });
    let body_text = serde_json::to_string(&body)?;
    let source_hash = format!("{:x}", Sha256::digest(text.as_bytes()));
    let now = chrono::Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
    let current = json!({
        "text": body_text,
        "sourceHash": source_hash,
        "model": "koe-desktop-organizer",
        "instruction": if instruction.trim().is_empty() { "会议纪要" } else { instruction.trim() },
        "sources": sources,
        "createdAt": now,
        "templateId": "meeting",
        "templateVersion": 2,
        "isDraft": false,
    });
    let mut history: Vec<Value> = existing
        .and_then(|m| m.get("history"))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if let Some(prev) = existing.and_then(|m| m.get("current")).cloned() {
        history.insert(0, prev);
    }
    history.truncate(10);
    let wrapped = json!({
        "current": current,
        "history": history,
    });
    minutes::validate(&wrapped).map_err(|e| anyhow::anyhow!("纪要结构校验未通过：{e}"))?;
    Ok(wrapped)
}

pub fn format_minutes(text: &str) -> String {
    let Ok(value) = serde_json::from_str::<Value>(text) else {
        return text.to_owned();
    };
    let mut lines = Vec::new();
    for (key, label) in [("title", "标题"), ("overview", "概览")] {
        if let Some(text) = value[key].as_str() {
            lines.push(format!("{label}：{text}"));
        }
    }
    for (key, label) in [
        ("topics", "议题"),
        ("decisions", "决定"),
        ("actions", "行动"),
        ("questions", "问题"),
        ("terms", "术语"),
        ("custom", "补充"),
        ("reviewItems", "待核对"),
    ] {
        if let Some(items) = value[key].as_array().filter(|items| !items.is_empty()) {
            lines.push(label.to_owned());
            for item in items {
                collect_minutes(item, &mut lines, 0);
            }
        }
    }
    if value["reviewItems"].is_null()
        && let Some(items) = value["review_items"]
            .as_array()
            .filter(|items| !items.is_empty())
    {
        lines.push("待核对".to_owned());
        for item in items {
            collect_minutes(item, &mut lines, 0);
        }
    }
    lines.join("\n")
}

fn collect_minutes(value: &Value, lines: &mut Vec<String>, depth: usize) {
    match value {
        Value::String(text) => lines.push(format!("{}{}", "  ".repeat(depth), text)),
        Value::Array(items) => {
            for item in items {
                collect_minutes(item, lines, depth);
            }
        }
        Value::Object(item) => {
            for (key, label) in [
                ("title", ""),
                ("text", ""),
                ("summary", "摘要："),
                ("name", ""),
                ("note", "说明："),
                ("owner", "负责人："),
                ("due", "期限："),
                ("question", "问题："),
                ("detail", "详情："),
            ] {
                if let Some(text) = item.get(key).and_then(|v| v.as_str()) {
                    lines.push(format!("{}{label}{text}", "  ".repeat(depth)));
                }
            }
            for key in ["points", "fishbone", "branches", "items", "heard"] {
                if let Some(value) = item.get(key) {
                    collect_minutes(value, lines, depth + 1);
                }
            }
        }
        _ => {}
    }
}
