use std::collections::BTreeSet;

use super::json::write_escaped_json_string;
use crate::domain::{MeetingMinutes, MinuteFishbone, MinutePoint, MinuteTerm, SegmentId};

fn replace_minute_terms(text: &str, replacements: &[(&str, &str)]) -> String {
    if text.is_empty() || replacements.is_empty() {
        return text.to_string();
    }
    let mut sorted: Vec<(&str, &str, usize)> = Vec::new();
    let mut seen_keys = BTreeSet::new();
    for &(from, to) in replacements {
        if !from.is_empty() && from != to && seen_keys.insert(from) {
            sorted.push((from, to, from.chars().count()));
        }
    }
    if sorted.is_empty() {
        return text.to_string();
    }
    sorted.sort_by(|a, b| b.2.cmp(&a.2).then_with(|| a.0.cmp(b.0)));

    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while !rest.is_empty() {
        let mut matched: Option<(&str, &str)> = None;
        for &(from, to, _) in &sorted {
            if rest.starts_with(from) {
                matched = Some((from, to));
                break;
            }
        }
        if let Some((from, to)) = matched {
            out.push_str(to);
            rest = &rest[from.len()..];
        } else if let Some(ch) = rest.chars().next() {
            out.push(ch);
            rest = &rest[ch.len_utf8()..];
        } else {
            break;
        }
    }
    out
}

impl MeetingMinutes {
    /// Returns the deduplicated set of all [`SegmentId`]s cited anywhere in this document.
    #[must_use]
    pub fn all_cited_ids(&self) -> BTreeSet<SegmentId> {
        let mut ids = BTreeSet::new();
        for t in &self.topics {
            ids.extend(t.citations.iter().copied());
            for p in &t.points {
                ids.extend(p.citations.iter().copied());
            }
            if let Some(fb) = &t.fishbone {
                for c in &fb.causes {
                    ids.extend(c.citations.iter().copied());
                }
            }
        }
        for d in &self.decisions {
            ids.extend(d.citations.iter().copied());
        }
        for a in &self.actions {
            ids.extend(a.citations.iter().copied());
        }
        for q in &self.questions {
            ids.extend(q.citations.iter().copied());
        }
        for fb in &self.fishbones {
            for c in &fb.causes {
                ids.extend(c.citations.iter().copied());
            }
        }
        for term in &self.terms {
            ids.extend(term.citations.iter().copied());
        }
        for sec in &self.custom_sections {
            for p in &sec.points {
                ids.extend(p.citations.iter().copied());
            }
        }
        ids
    }

    /// Applies single-pass longest-match term replacement across all text fields, custom section
    /// headings, and `terms` (merging duplicate term names after replacement).
    pub fn replace_terms(&mut self, replacements: &[(&str, &str)]) {
        if replacements.is_empty() {
            return;
        }
        let r = |s: &str| replace_minute_terms(s, replacements);
        self.title = r(&self.title);
        self.overview = r(&self.overview);

        let replace_point = |pt: &mut MinutePoint| {
            pt.claim = r(&pt.claim);
            pt.owner = pt.owner.as_deref().map(r);
            pt.due = pt.due.as_deref().map(r);
            pt.speaker = pt.speaker.as_deref().map(r);
        };
        let replace_fb = |fb: &mut MinuteFishbone| {
            fb.issue = r(&fb.issue);
            for c in &mut fb.causes {
                c.category = r(&c.category);
                c.description = r(&c.description);
            }
        };

        for t in &mut self.topics {
            t.title = r(&t.title);
            t.summary = r(&t.summary);
            for pt in &mut t.points {
                replace_point(pt);
            }
            if let Some(fb) = &mut t.fishbone {
                replace_fb(fb);
            }
        }
        for d in &mut self.decisions {
            replace_point(d);
        }
        for a in &mut self.actions {
            replace_point(a);
        }
        for q in &mut self.questions {
            replace_point(q);
        }
        for fb in &mut self.fishbones {
            replace_fb(fb);
        }
        for sec in &mut self.custom_sections {
            sec.heading = r(&sec.heading);
            for pt in &mut sec.points {
                replace_point(pt);
            }
        }
        self.review_items = self.review_items.iter().map(|s| r(s)).collect();

        let mut merged_terms: Vec<MinuteTerm> = Vec::new();
        for term in &self.terms {
            let next_name = r(&term.term);
            let next_note = r(&term.definition);
            let mut next_heard = Vec::new();
            for h in &term.heard {
                let rh = r(h);
                if rh != next_name && !next_heard.contains(&rh) {
                    next_heard.push(rh);
                }
            }
            if let Some(existing) = merged_terms.iter_mut().find(|t| t.term == next_name) {
                for h in next_heard {
                    if !existing.heard.contains(&h) {
                        existing.heard.push(h);
                    }
                }
                for &cid in &term.citations {
                    if !existing.citations.contains(&cid) {
                        existing.citations.push(cid);
                    }
                }
            } else {
                merged_terms.push(MinuteTerm {
                    term: next_name,
                    definition: next_note,
                    heard: next_heard,
                    adoption: term.adoption,
                    citations: term.citations.clone(),
                });
            }
        }
        self.terms = merged_terms;
    }

    /// Replaces `old_name` with `new_name` across all fields (`replaceSpeakerName`).
    pub fn replace_speaker_name(&mut self, old_name: &str, new_name: &str) {
        let from = old_name.trim();
        let to = new_name.trim();
        if from.is_empty() || to.is_empty() || from == to {
            return;
        }
        self.replace_terms(&[(from, to)]);
    }

    /// Removes a specific `heard` spelling from the term matching `term_name` (`pruneHeard`).
    pub fn prune_heard(&mut self, term_name: &str, heard_spelling: &str) {
        for t in &mut self.terms {
            if t.term == term_name {
                t.heard.retain(|h| h != heard_spelling);
            }
        }
    }
}

/// Builds the trilingual (`zh` / `en` / `ja`) meeting minutes LLM system/user prompt with
/// optional custom template sections, custom instructions, and hot-word vocabulary hints.
#[must_use]
pub fn build_meeting_minutes_prompt(
    numbered_transcript: &str,
    locale_code: &str,
    custom_sections: &[String],
    custom_instructions: Option<&str>,
    vocabulary: &[String],
) -> String {
    let sections: Vec<String> = custom_sections
        .iter()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();

    let extra = custom_instructions
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| format!("\n- {s}"))
        .unwrap_or_default();

    let clean_vocab: Vec<String> = vocabulary
        .iter()
        .map(|w| w.trim().to_string())
        .filter(|w| !w.is_empty())
        .take(200)
        .collect();

    let mut custom_schema = String::new();
    let mut custom_rule = extra.clone();
    if !sections.is_empty() {
        let entries: Vec<String> = sections
            .iter()
            .map(|h| {
                let mut key = String::new();
                write_escaped_json_string(h, &mut key);
                format!("    {key}: [{{ \"text\": \"...\", \"sources\": [\"S1\"] }}]")
            })
            .collect();
        custom_schema = format!(",\n  \"custom\": {{\n{}\n  }}", entries.join(",\n"));
        custom_rule = match locale_code {
            "en" => format!(
                "\n- Fill \"custom\" with the template sections ({}); use [] when a section has no grounded points.{extra}",
                sections.join(", ")
            ),
            "ja" => format!(
                "\n- \"custom\" にはテンプレートの各セクション（{}）を入れ、該当がない場合は [] にしてください。{extra}",
                sections.join("、")
            ),
            _ => format!(
                "\n- 按模板填写 \"custom\" 中的各个分栏（{}），原话未提及时填 []。{extra}",
                sections.join("、")
            ),
        };
    }

    let vocab_rule = if clean_vocab.is_empty() {
        String::new()
    } else {
        let joined = clean_vocab.join(", ");
        match locale_code {
            "en" => format!(
                "\n- Known terms / proper nouns (correct obvious homophone ASR errors to these spellings when context matches, and cite the original sentence): {joined}"
            ),
            "ja" => format!(
                "\n- 既知の固有名詞・専門用語（同音異字の認識誤りがあれば文脈に応じてこの表記に揃え、元の文の番号を引用してください）：{joined}"
            ),
            _ => format!(
                "\n- 已知专有名词/术语表（若原话中有同音或近音识别错误，请在纪要与 terms.name 中统一写成以下标准写法，并在 terms.heard 中列出原话里实际出现的错别字，同时引用原句编号）：{}",
                clean_vocab.join("、")
            ),
        }
    };

    match locale_code {
        "en" => format!(
            "Turn the numbered transcript below into structured meeting minutes.\nReturn ONLY a single JSON object (no markdown fences, no commentary) matching this exact schema:\n{{\n  \"schemaVersion\": 2,\n  \"title\": \"Concise title (<= 16 words)\",\n  \"overview\": \"2-4 sentence executive summary\",\n  \"topics\": [\n    {{\n      \"text\": \"Topic title\",\n      \"summary\": \"1-2 sentence synthesis of this topic\",\n      \"sources\": [\"S1\", \"S2\"],\n      \"points\": [\n        {{ \"text\": \"Specific viewpoint, argument, or fact\", \"sources\": [\"S1\"] }}\n      ],\n      \"fishbone\": {{\n        \"question\": \"Core problem or question (optional: include ONLY when the topic analyzes causes of an issue)\",\n        \"branches\": [\n          {{ \"text\": \"Cause category\", \"detail\": \"Specific cause\", \"sources\": [\"S2\"] }}\n        ]\n      }}\n    }}\n  ],\n  \"decisions\": [\n    {{ \"text\": \"Decision reached\", \"sources\": [\"S3\"] }}\n  ],\n  \"actions\": [\n    {{ \"text\": \"Concrete next step\", \"owner\": \"Person (optional)\", \"due\": \"Deadline (optional)\", \"sources\": [\"S4\"] }}\n  ],\n  \"questions\": [\n    {{ \"text\": \"Unresolved question or risk\", \"sources\": [\"S5\"] }}\n  ],\n  \"terms\": [\n    {{ \"name\": \"Proper noun or domain term (<= 6 items)\", \"note\": \"Brief role or meaning in this recording\", \"heard\": [\"Exact substring in cited S# if ASR misheard it\"], \"sources\": [\"S1\"] }}\n  ],\n  \"reviewItems\": [\"S3: possible ASR error or ambiguity worth checking\"]{custom_schema}\n}}\n\nStrict grounding rules:\n- Every item in topics, topic.points, fishbone.branches, decisions, actions, questions, and terms MUST have a non-empty \"sources\" array containing only sentence IDs (S1, S2, ...) that directly support it.\n- Never invent facts, numbers, ratios, formulas, or deadlines not stated in the transcript.\n- Never combine numbers from different sentences to infer a formula or calculation (e.g., do NOT write \"salary is base * 80%\" or \"calculated at 80% of X\" unless a single source sentence explicitly states that exact calculation).\n- Use [] for any list that has no grounded items; omit \"fishbone\" when a topic is not a root-cause discussion; omit \"owner\" / \"due\" when not explicitly mentioned.\n- In \"terms.heard\", include ONLY exact substrings that literally appear in the cited sentences when ASR misheard the term; omit \"heard\" if the transcript already uses the canonical spelling.\n- Keep the language of the transcript.{custom_rule}{vocab_rule}\n\nNumbered transcript:\n{numbered_transcript}"
        ),
        "ja" => format!(
            "以下の番号付き文字起こしから構造化された議事録を作成してください。\nマークダウンのコードブロックや説明文は一切付けず、次のスキーマに厳密に従う JSON オブジェクトのみを返してください:\n{{\n  \"schemaVersion\": 2,\n  \"title\": \"簡潔なタイトル（25文字以内）\",\n  \"overview\": \"2〜4文の要約\",\n  \"topics\": [\n    {{\n      \"text\": \"トピック見出し\",\n      \"summary\": \"このトピックの1〜2文のまとめ\",\n      \"sources\": [\"S1\", \"S2\"],\n      \"points\": [\n        {{ \"text\": \"具体的な発言・論点・事実\", \"sources\": [\"S1\"] }}\n      ],\n      \"fishbone\": {{\n        \"question\": \"中心となる問題・問い（原因分析をしているトピックのみ任意で記載）\",\n        \"branches\": [\n          {{ \"text\": \"要因カテゴリ\", \"detail\": \"具体的な原因\", \"sources\": [\"S2\"] }}\n        ]\n      }}\n    }}\n  ],\n  \"decisions\": [\n    {{ \"text\": \"決定事項\", \"sources\": [\"S3\"] }}\n  ],\n  \"actions\": [\n    {{ \"text\": \"具体的な次のアクション\", \"owner\": \"担当者（任意）\", \"due\": \"期限（任意）\", \"sources\": [\"S4\"] }}\n  ],\n  \"questions\": [\n    {{ \"text\": \"未解決の課題・疑問\", \"sources\": [\"S5\"] }}\n  ],\n  \"terms\": [\n    {{ \"name\": \"固有名詞・専門用語（最大6件）\", \"note\": \"この録音における簡単な説明\", \"heard\": [\"誤変換されている場合、引用した S# 内に実際に出現する文字列\"], \"sources\": [\"S1\"] }}\n  ],\n  \"reviewItems\": [\"S3: 認識誤りや曖昧さがあり確認が必要な箇所\"]{custom_schema}\n}}\n\n厳守事項:\n- topics、topic.points、fishbone.branches、decisions、actions、questions、terms の各要素には、根拠となる文番号（S1, S2, ...）のみを含む非空の \"sources\" 配列を必ず付けてください。\n- 文字起こしにない事実・数値・割合・計算式・期限を絶対に創作しないでください。\n- 複数の文の数値を組み合わせて計算式や割合を推測しないでください（1つの文で明言されていない限り「基本給×80%」「Xの80%で計算」等と書かないこと）。\n- 該当がない配列は [] にし、原因分析でないトピックでは \"fishbone\" を省略し、明言されていない \"owner\" / \"due\" は省略してください。\n- \"terms.heard\" には、音声認識の誤りがある場合に引用元の文にそのまま含まれる部分文字列のみを入れてください。元の文がすでに正しい表記なら \"heard\" は省略してください。{custom_rule}{vocab_rule}\n\n番号付き文字起こし:\n{numbered_transcript}"
        ),
        _ => format!(
            "请根据下方带编号的逐句原话，整理结构化闪记纪要。\n只返回一个 JSON 对象（不要 ``` 代码块，不要任何额外说明），严格符合以下结构：\n{{\n  \"schemaVersion\": 2,\n  \"title\": \"简短标题（20字以内）\",\n  \"overview\": \"2到4句话的整体概述\",\n  \"topics\": [\n    {{\n      \"text\": \"主题标题\",\n      \"summary\": \"1到2句话概括该主题的核心内容\",\n      \"sources\": [\"S1\", \"S2\"],\n      \"points\": [\n        {{ \"text\": \"该主题下的具体观点、论据或事实\", \"sources\": [\"S1\"] }}\n      ],\n      \"fishbone\": {{\n        \"question\": \"核心问题（可选：仅在该主题讨论问题成因/故障排查时填写）\",\n        \"branches\": [\n          {{ \"text\": \"原因类别（如人员/流程/环境）\", \"detail\": \"具体原因说明\", \"sources\": [\"S2\"] }}\n        ]\n      }}\n    }}\n  ],\n  \"decisions\": [\n    {{ \"text\": \"已达成的决定或结论\", \"sources\": [\"S3\"] }}\n  ],\n  \"actions\": [\n    {{ \"text\": \"具体待办事项\", \"owner\": \"负责人（原话未提则省略）\", \"due\": \"期限（原话未提则省略）\", \"sources\": [\"S4\"] }}\n  ],\n  \"questions\": [\n    {{ \"text\": \"未解决的问题或风险\", \"sources\": [\"S5\"] }}\n  ],\n  \"terms\": [\n    {{ \"name\": \"专有名词/人名/项目名/术语（最多6个）\", \"note\": \"在本次录音中的简短说明\", \"heard\": [\"若原话被识别成同音错字，填所引原句中实际出现的错字子串\"], \"sources\": [\"S1\"] }}\n  ],\n  \"reviewItems\": [\"S3：疑似识别有误或表述含糊、建议人工复核的地方\"]{custom_schema}\n}}\n\n严格约束：\n- topics、topic.points、fishbone.branches、decisions、actions、questions、terms 中的每一条都必须带有非空的 \"sources\" 数组，且只能引用直接支撑该条内容的原句编号（S1、S2……）。\n- 严禁编造原话中没有的事实、数字、比例、计算公式、人名或期限。\n- 严禁把不同句子的数字拼在一起推算工资、基数或比例公式（例如原话未在同一句明确说出“按基本工资乘以80%计算”，绝不能自行合成此类算式）。\n- 没有对应内容的列表填 []；非原因分析的主题省略 \"fishbone\"；未明确提及的 \"owner\" / \"due\" 直接省略字段。\n- \"terms.heard\" 只能填写所引原句（sources）中逐字出现过的错别字子串；若原话本身写法正确则省略 \"heard\"。{custom_rule}{vocab_rule}\n\n带编号原话：\n{numbered_transcript}"
        ),
    }
}
