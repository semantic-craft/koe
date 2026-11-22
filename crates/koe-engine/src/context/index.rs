use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet};

const fn pack_pair(c1: char, c2: char) -> u32 {
    ((c1 as u32) << 16) | (c2 as u32)
}

const fn sort_u32_array<const N: usize>(mut arr: [u32; N]) -> [u32; N] {
    let mut i = 0;
    while i < N {
        let mut j = i + 1;
        while j < N {
            if arr[j] < arr[i] {
                arr.swap(i, j);
            }
            j += 1;
        }
        i += 1;
    }
    arr
}

const STOP_PAIR_KEYS: [u32; 27] = sort_u32_array([
    pack_pair('什', '么'),
    pack_pair('怎', '么'),
    pack_pair('我', '们'),
    pack_pair('你', '们'),
    pack_pair('他', '们'),
    pack_pair('一', '下'),
    pack_pair('这', '个'),
    pack_pair('那', '个'),
    pack_pair('是', '不'),
    pack_pair('不', '是'),
    pack_pair('有', '没'),
    pack_pair('没', '有'),
    pack_pair('可', '以'),
    pack_pair('就', '是'),
    pack_pair('还', '是'),
    pack_pair('然', '后'),
    pack_pair('因', '为'),
    pack_pair('所', '以'),
    pack_pair('如', '果'),
    pack_pair('时', '候'),
    pack_pair('一', '个'),
    pack_pair('的', '话'),
    pack_pair('了', '吗'),
    pack_pair('是', '什'),
    pack_pair('么', '时'),
    pack_pair('吗', '？'),
    pack_pair('问', '一'),
]);

#[inline]
fn is_stop_pair_key(key: u32) -> bool {
    STOP_PAIR_KEYS.binary_search(&key).is_ok()
}

#[inline]
fn is_cjk_ideograph(c: char) -> bool {
    ('\u{4E00}'..='\u{9FFF}').contains(&c)
}

#[must_use]
fn stem_latin_token(token: &str) -> &str {
    if token.len() < 4 || !token.bytes().all(|b| b.is_ascii_lowercase()) {
        return token;
    }
    for suffix in [
        "ings", "edly", "tion", "ment", "ing", "ies", "ed", "es", "ly", "s",
    ] {
        if let Some(stem) = token.strip_suffix(suffix) {
            if stem.len() >= 3 {
                return stem;
            }
        }
    }
    token
}

fn for_each_cjk_bigram(text: &str, mut on_bigram: impl FnMut(u32)) -> u32 {
    let mut char_len = 0u32;
    let mut prev_han: Option<char> = None;
    for ch in text.chars() {
        char_len = char_len.saturating_add(1);
        if is_cjk_ideograph(ch) {
            if let Some(prev) = prev_han {
                let key = pack_pair(prev, ch);
                if !is_stop_pair_key(key) {
                    on_bigram(key);
                }
            }
            prev_han = Some(ch);
        } else {
            prev_han = None;
        }
    }
    char_len
}

fn for_each_latin_term_with_scratch(
    text: &str,
    scratch: &mut String,
    mut on_term: impl FnMut(&str),
) {
    let bytes = text.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i].is_ascii_alphanumeric() {
            let start = i;
            i += 1;
            while i < bytes.len() && bytes[i].is_ascii_alphanumeric() {
                i += 1;
            }
            if i - start >= 2 {
                let raw = &text[start..i];
                let tok = if raw.bytes().all(|b| !b.is_ascii_uppercase()) {
                    raw
                } else {
                    scratch.clear();
                    scratch.push_str(raw);
                    scratch.make_ascii_lowercase();
                    scratch.as_str()
                };
                on_term(tok);
                let stem = stem_latin_token(tok);
                if stem != tok {
                    on_term(stem);
                }
            }
        } else {
            i += 1;
        }
    }
}

fn for_each_latin_term(text: &str, on_term: impl FnMut(&str)) {
    let mut scratch = String::new();
    for_each_latin_term_with_scratch(text, &mut scratch, on_term);
}

fn extract_query_terms(query: &str) -> (BTreeSet<u32>, BTreeSet<String>) {
    let mut cjk_keys = BTreeSet::new();
    let _ = for_each_cjk_bigram(query, |key| {
        cjk_keys.insert(key);
    });
    let mut latin_keys = BTreeSet::new();
    for_each_latin_term(query, |term| {
        if !latin_keys.contains(term) {
            latin_keys.insert(term.to_owned());
        }
    });
    (cjk_keys, latin_keys)
}

fn collect_ranked_hits(scores: &[f64], touched: Vec<usize>, limit: usize) -> Vec<SearchHit> {
    let mut hits: Vec<SearchHit> = touched
        .into_iter()
        .filter_map(|idx| {
            let s = scores[idx];
            if s > 0.0 {
                Some(SearchHit {
                    doc_index: idx,
                    score: s,
                })
            } else {
                None
            }
        })
        .collect();

    hits.sort_by(|a, b| {
        b.score
            .partial_cmp(&a.score)
            .unwrap_or(Ordering::Equal)
            .then_with(|| a.doc_index.cmp(&b.doc_index))
    });
    if hits.len() > limit {
        hits.truncate(limit);
    }
    hits
}

/// Scoring mode for [`ContextSearchIndex::search`].
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ScoringMode {
    /// Sum of `ln(1 + N / df)` across matching query terms.
    IdfSum,
    /// Okapi BM25 scoring with saturation `k1` and document-length normalization `b`.
    Bm25 {
        /// Term-frequency saturation parameter (typically `1.2`).
        k1: f64,
        /// Document-length normalization parameter (typically `0.75`).
        b: f64,
    },
}

impl Default for ScoringMode {
    fn default() -> Self {
        Self::Bm25 { k1: 1.2, b: 0.75 }
    }
}

/// Ranked document hit returned by [`ContextSearchIndex::search`].
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SearchHit {
    /// Zero-based document index in the corpus.
    pub doc_index: usize,
    /// Relevance score (`> 0.0`).
    pub score: f64,
}

/// Inverted index over Chinese 2-character bigrams (`u32` packed keys) and Latin tokens/stems
/// for offline Q&A retrieval.
#[derive(Debug, Clone, Default)]
pub struct ContextSearchIndex {
    doc_count: usize,
    total_chars: usize,
    doc_char_lens: Vec<u32>,
    cjk_postings: BTreeMap<u32, Vec<(u32, u16)>>,
    latin_postings: BTreeMap<String, Vec<(u32, u16)>>,
    last_hit_count: usize,
}

impl ContextSearchIndex {
    /// Creates an empty [`ContextSearchIndex`].
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Builds a [`ContextSearchIndex`] from a slice of document texts.
    #[must_use]
    pub fn build(texts: &[&str]) -> Self {
        let mut index = Self {
            doc_count: 0,
            total_chars: 0,
            doc_char_lens: Vec::with_capacity(texts.len()),
            cjk_postings: BTreeMap::new(),
            latin_postings: BTreeMap::new(),
            last_hit_count: 0,
        };
        for text in texts {
            let _ = index.add_document(text);
        }
        index
    }

    /// Indexes a single document and returns its 0-based `doc_index`.
    pub fn add_document(&mut self, text: &str) -> usize {
        let doc_id = self.doc_count as u32;
        self.doc_count += 1;

        let mut cjk_tf: BTreeMap<u32, u16> = BTreeMap::new();
        let char_len = for_each_cjk_bigram(text, |key| {
            let count = cjk_tf.entry(key).or_insert(0);
            *count = count.saturating_add(1);
        });

        self.total_chars = self.total_chars.saturating_add(char_len as usize);
        self.doc_char_lens.push(char_len.max(1));

        for (key, tf) in cjk_tf {
            self.cjk_postings.entry(key).or_default().push((doc_id, tf));
        }

        let mut latin_tf: BTreeMap<String, u16> = BTreeMap::new();
        for_each_latin_term(text, |term| {
            if let Some(count) = latin_tf.get_mut(term) {
                *count = count.saturating_add(1);
            } else {
                latin_tf.insert(term.to_owned(), 1);
            }
        });

        for (term, tf) in latin_tf {
            self.latin_postings
                .entry(term)
                .or_default()
                .push((doc_id, tf));
        }

        doc_id as usize
    }

    /// Returns the number of indexed documents.
    #[must_use]
    pub const fn doc_count(&self) -> usize {
        self.doc_count
    }

    /// Returns the total number of Unicode characters across all indexed documents.
    #[must_use]
    pub const fn total_chars(&self) -> usize {
        self.total_chars
    }

    /// Returns the total number of unique CJK bigram + Latin terms in the index vocabulary.
    #[must_use]
    pub fn vocab_size(&self) -> usize {
        self.cjk_postings.len() + self.latin_postings.len()
    }

    /// Returns the hit count from the most recent [`Self::query_indices`] call.
    #[must_use]
    pub const fn last_hit_count(&self) -> usize {
        self.last_hit_count
    }

    /// Searches the index for `query` under `mode`, returning at most `limit` [`SearchHit`]s
    /// ordered by score descending, then `doc_index` ascending.
    #[must_use]
    pub fn search(&self, query: &str, limit: usize, mode: ScoringMode) -> Vec<SearchHit> {
        if self.doc_count == 0 || limit == 0 {
            return Vec::new();
        }

        let (cjk_keys, latin_keys) = extract_query_terms(query);
        if cjk_keys.is_empty() && latin_keys.is_empty() {
            return Vec::new();
        }

        let n = self.doc_count as f64;
        let avgdl = (self.total_chars as f64 / n).max(1.0);
        let mut scores = vec![0.0f64; self.doc_count];
        let mut touched = Vec::new();

        let mut accumulate = |postings: &[(u32, u16)]| {
            if postings.is_empty() {
                return;
            }
            let df = postings.len() as f64;
            let idf = (1.0 + n / df).ln();
            for &(doc_id, tf) in postings {
                let idx = doc_id as usize;
                if scores[idx] == 0.0 {
                    touched.push(idx);
                }
                let term_score = match mode {
                    ScoringMode::IdfSum => idf,
                    ScoringMode::Bm25 { k1, b } => {
                        let tf_f = f64::from(tf);
                        let dl = f64::from(self.doc_char_lens[idx]);
                        let norm = tf_f * (k1 + 1.0) / (tf_f + k1 * (1.0 - b + b * (dl / avgdl)));
                        idf * norm
                    }
                };
                scores[idx] += term_score;
            }
        };

        for key in cjk_keys {
            if let Some(postings) = self.cjk_postings.get(&key) {
                accumulate(postings);
            }
        }
        for term in latin_keys {
            if let Some(postings) = self.latin_postings.get(&term) {
                accumulate(postings);
            }
        }

        collect_ranked_hits(&scores, touched, limit)
    }

    /// Searches using default BM25 scoring, updates `last_hit_count`, and returns matching document indices.
    pub fn query_indices(&mut self, query: &str, limit: usize) -> Vec<usize> {
        let hits = self.search(query, limit, ScoringMode::default());
        self.last_hit_count = hits.len();
        hits.into_iter().map(|h| h.doc_index).collect()
    }
}

/// Ranks `texts` against `query` using IDF-weighted Chinese character bigrams and Latin words
/// (`ln(1 + N / df)`), returning at most `limit` 0-based indices in descending score order.
#[must_use]
pub fn rank_texts(query: &str, texts: &[&str], limit: usize) -> Vec<usize> {
    if texts.is_empty() || limit == 0 {
        return Vec::new();
    }

    let (cjk_keys, latin_keys) = extract_query_terms(query);
    if cjk_keys.is_empty() && latin_keys.is_empty() {
        return Vec::new();
    }

    let mut cjk_term_ids: BTreeMap<u32, usize> = BTreeMap::new();
    for key in cjk_keys {
        let tid = cjk_term_ids.len();
        cjk_term_ids.insert(key, tid);
    }
    let cjk_count = cjk_term_ids.len();

    let mut latin_term_ids: BTreeMap<String, usize> = BTreeMap::new();
    for term in latin_keys {
        let tid = cjk_count + latin_term_ids.len();
        latin_term_ids.insert(term, tid);
    }
    let total_terms = cjk_count + latin_term_ids.len();

    let mut postings: Vec<Vec<usize>> = vec![Vec::new(); total_terms];
    let mut doc_seen = vec![usize::MAX; total_terms];
    let mut scratch = String::new();
    let mut any_match = false;

    for (doc_idx, &text) in texts.iter().enumerate() {
        if !cjk_term_ids.is_empty() {
            let _ = for_each_cjk_bigram(text, |key| {
                if let Some(&tid) = cjk_term_ids.get(&key) {
                    if doc_seen[tid] != doc_idx {
                        doc_seen[tid] = doc_idx;
                        postings[tid].push(doc_idx);
                        any_match = true;
                    }
                }
            });
        }
        if !latin_term_ids.is_empty() {
            for_each_latin_term_with_scratch(text, &mut scratch, |term| {
                if let Some(&tid) = latin_term_ids.get(term) {
                    if doc_seen[tid] != doc_idx {
                        doc_seen[tid] = doc_idx;
                        postings[tid].push(doc_idx);
                        any_match = true;
                    }
                }
            });
        }
    }

    if !any_match {
        return Vec::new();
    }

    let n = texts.len() as f64;
    let mut scores = vec![0.0f64; texts.len()];
    let mut touched = Vec::new();
    for doc_ids in &postings {
        if doc_ids.is_empty() {
            continue;
        }
        let idf = (1.0 + n / doc_ids.len() as f64).ln();
        for &doc_idx in doc_ids {
            if scores[doc_idx] == 0.0 {
                touched.push(doc_idx);
            }
            scores[doc_idx] += idf;
        }
    }

    collect_ranked_hits(&scores, touched, limit)
        .into_iter()
        .map(|hit| hit.doc_index)
        .collect()
}
