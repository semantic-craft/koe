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
/// for sub-millisecond offline Q&A retrieval over 400,000-character corpora.
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

        let mut char_len = 0u32;
        let mut cjk_tf: BTreeMap<u32, u16> = BTreeMap::new();
        let mut prev_han: Option<char> = None;

        for ch in text.chars() {
            char_len = char_len.saturating_add(1);
            if is_cjk_ideograph(ch) {
                if let Some(p) = prev_han {
                    let key = pack_pair(p, ch);
                    if !is_stop_pair_key(key) {
                        let count = cjk_tf.entry(key).or_insert(0);
                        *count = count.saturating_add(1);
                    }
                }
                prev_han = Some(ch);
            } else {
                prev_han = None;
            }
        }

        self.total_chars = self.total_chars.saturating_add(char_len as usize);
        self.doc_char_lens.push(char_len.max(1));

        for (key, tf) in cjk_tf {
            self.cjk_postings.entry(key).or_default().push((doc_id, tf));
        }

        let bytes = text.as_bytes();
        let mut latin_tf: BTreeMap<String, u16> = BTreeMap::new();
        let mut i = 0;
        while i < bytes.len() {
            if bytes[i].is_ascii_alphanumeric() {
                let start = i;
                i += 1;
                while i < bytes.len() && bytes[i].is_ascii_alphanumeric() {
                    i += 1;
                }
                if i - start >= 2 {
                    let tok = text[start..i].to_ascii_lowercase();
                    let stem = stem_latin_token(&tok).to_string();
                    let count = latin_tf.entry(tok.clone()).or_insert(0);
                    *count = count.saturating_add(1);
                    if stem != tok {
                        let stem_count = latin_tf.entry(stem).or_insert(0);
                        *stem_count = stem_count.saturating_add(1);
                    }
                }
            } else {
                i += 1;
            }
        }

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

        let mut cjk_keys = BTreeSet::new();
        let mut prev_han: Option<char> = None;
        for ch in query.chars() {
            if is_cjk_ideograph(ch) {
                if let Some(p) = prev_han {
                    let key = pack_pair(p, ch);
                    if !is_stop_pair_key(key) {
                        cjk_keys.insert(key);
                    }
                }
                prev_han = Some(ch);
            } else {
                prev_han = None;
            }
        }

        let mut latin_keys = BTreeSet::new();
        let bytes = query.as_bytes();
        let mut i = 0;
        while i < bytes.len() {
            if bytes[i].is_ascii_alphanumeric() {
                let start = i;
                i += 1;
                while i < bytes.len() && bytes[i].is_ascii_alphanumeric() {
                    i += 1;
                }
                if i - start >= 2 {
                    let tok = query[start..i].to_ascii_lowercase();
                    let stem = stem_latin_token(&tok).to_string();
                    latin_keys.insert(tok.clone());
                    if stem != tok {
                        latin_keys.insert(stem);
                    }
                }
            } else {
                i += 1;
            }
        }

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

    let mut cjk_patterns: Vec<[u8; 6]> = Vec::new();
    let mut cjk_seen: Vec<u32> = Vec::new();
    let mut prev_han: Option<char> = None;
    for ch in query.chars() {
        if is_cjk_ideograph(ch) {
            if let Some(p) = prev_han {
                let key = pack_pair(p, ch);
                if !is_stop_pair_key(key) && !cjk_seen.contains(&key) {
                    cjk_seen.push(key);
                    let mut buf = [0u8; 6];
                    let _ = p.encode_utf8(&mut buf[0..3]);
                    let _ = ch.encode_utf8(&mut buf[3..6]);
                    cjk_patterns.push(buf);
                }
            }
            prev_han = Some(ch);
        } else {
            prev_han = None;
        }
    }

    let mut latin_terms: Vec<Vec<u8>> = Vec::new();
    let q_bytes = query.as_bytes();
    let mut i = 0;
    while i < q_bytes.len() {
        if q_bytes[i].is_ascii_alphanumeric() {
            let start = i;
            i += 1;
            while i < q_bytes.len() && q_bytes[i].is_ascii_alphanumeric() {
                i += 1;
            }
            if i - start >= 2 {
                let tok: Vec<u8> = q_bytes[start..i]
                    .iter()
                    .map(u8::to_ascii_lowercase)
                    .collect();
                if !latin_terms.contains(&tok) {
                    latin_terms.push(tok);
                }
            }
        } else {
            i += 1;
        }
    }

    let cjk_len = cjk_patterns.len().min(64);
    cjk_patterns.truncate(cjk_len);
    let latin_len = latin_terms.len().min(64 - cjk_len);
    latin_terms.truncate(latin_len);
    let total_terms = cjk_len + latin_len;
    if total_terms == 0 {
        return Vec::new();
    }

    let mut b2_mask = [0u64; 256];
    let mut b5_mask = [0u64; 256];
    for (k, pat) in cjk_patterns.iter().enumerate() {
        b2_mask[pat[2] as usize] |= 1u64 << k;
        b5_mask[pat[5] as usize] |= 1u64 << k;
    }

    let mut latin_b0_mask = [0u64; 256];
    for (l_idx, pat) in latin_terms.iter().enumerate() {
        let bit = 1u64 << l_idx;
        let lo = pat[0];
        latin_b0_mask[lo as usize] |= bit;
        latin_b0_mask[lo.to_ascii_uppercase() as usize] |= bit;
    }

    let mut dfs = [0u32; 64];
    let mut matched_docs: Vec<(u32, u64)> = Vec::new();

    for (doc_idx, &text) in texts.iter().enumerate() {
        let mut mask = 0u64;
        let bytes = text.as_bytes();
        let len = bytes.len();

        if cjk_len > 0 && len >= 6 {
            let limit_bi = len - 6;
            let mut bi = 0;
            while bi <= limit_bi {
                let b0 = bytes[bi];
                if b0 < 0x80 {
                    bi += 1;
                } else if (0xE0..0xF0).contains(&b0) {
                    let cand =
                        b2_mask[bytes[bi + 2] as usize] & b5_mask[bytes[bi + 5] as usize] & !mask;
                    if cand != 0 {
                        let mut m = cand;
                        while m != 0 {
                            let k = m.trailing_zeros() as usize;
                            let pat = &cjk_patterns[k];
                            if b0 == pat[0]
                                && bytes[bi + 1] == pat[1]
                                && bytes[bi + 3] == pat[3]
                                && bytes[bi + 4] == pat[4]
                            {
                                mask |= 1u64 << k;
                            }
                            m &= m - 1;
                        }
                    }
                    bi += 3;
                } else if b0 < 0xE0 {
                    bi += 2;
                } else {
                    bi += 4;
                }
            }
        }

        if latin_len > 0 {
            let mut bi = 0;
            while bi < len {
                let b0 = bytes[bi];
                if b0 < 0x80 {
                    let cand = latin_b0_mask[b0 as usize] & !(mask >> cjk_len);
                    if cand != 0 {
                        let mut m = cand;
                        while m != 0 {
                            let l_idx = m.trailing_zeros() as usize;
                            let pat = &latin_terms[l_idx];
                            let pat_len = pat.len();
                            if bi + pat_len <= len {
                                let mut ok = true;
                                let mut j = 1;
                                while j < pat_len {
                                    if bytes[bi + j].to_ascii_lowercase() != pat[j] {
                                        ok = false;
                                        break;
                                    }
                                    j += 1;
                                }
                                if ok {
                                    mask |= 1u64 << (cjk_len + l_idx);
                                }
                            }
                            m &= m - 1;
                        }
                    }
                    bi += 1;
                } else if (0xE0..0xF0).contains(&b0) {
                    bi += 3;
                } else if b0 < 0xE0 {
                    bi += 2;
                } else {
                    bi += 4;
                }
            }
        }

        if mask != 0 {
            let mut m = mask;
            while m != 0 {
                let bit = m.trailing_zeros() as usize;
                dfs[bit] += 1;
                m &= m - 1;
            }
            matched_docs.push((doc_idx as u32, mask));
        }
    }

    if matched_docs.is_empty() {
        return Vec::new();
    }

    let n_f64 = texts.len() as f64;
    let mut weights = [0.0f64; 64];
    for t in 0..total_terms {
        if dfs[t] > 0 {
            weights[t] = (1.0 + n_f64 / f64::from(dfs[t])).ln();
        }
    }

    let mut scored: Vec<(usize, f64)> = Vec::with_capacity(matched_docs.len());
    for (doc_id, mask) in matched_docs {
        let mut score = 0.0f64;
        let mut m = mask;
        while m != 0 {
            let bit = m.trailing_zeros() as usize;
            score += weights[bit];
            m &= m - 1;
        }
        if score > 0.0 {
            scored.push((doc_id as usize, score));
        }
    }

    scored.sort_by(|a, b| {
        b.1.partial_cmp(&a.1)
            .unwrap_or(Ordering::Equal)
            .then_with(|| a.0.cmp(&b.0))
    });
    scored.into_iter().take(limit).map(|(idx, _)| idx).collect()
}
