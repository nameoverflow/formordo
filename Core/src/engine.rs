use crate::code::{expand_wildcards, PackedCode};
use crate::config::{FourthEmptyBehavior, ShiftToggleMode, WubiConfig, WubiSchema};
use crate::format::{AuxView, DictView, ENTRY_FLAG_SYMBOL};
use crate::neural::NeuralContextTracker;
use crate::typo::{generate_hypotheses, softmax_confidences, CorrectionKind, KeyLayout, KeyObs};
use crate::user_data::UserStore;
use std::collections::{HashMap, HashSet};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum CandidateBadge {
    None = 0,
    /// 该字存在更短简码（如全码输入时提示 ⚡q）
    Shortcode = 1,
    /// 统计 + 触控热区误触纠正候选项
    TypoCorrected = 2,
    /// z 通配符匹配项
    Wildcard = 3,
    /// z 引导拼音反查项
    PinyinLookup = 4,
    /// 用户自造词 / 自动组词词条
    UserPhrase = 5,
}

#[derive(Clone, Debug)]
pub struct Candidate {
    pub text: String,
    pub matched_code: PackedCode,
    /// 附加编码或反查说明（如简码 `"q"`、纠错原码 `"trwu"`、拼音反查 `"k · khk (zhōng)"`）
    pub comment: String,
    pub badge: CandidateBadge,
    /// 归一化后验置信度 `0.0 ..= 1.0`
    pub confidence: f32,
    pub is_exact: bool,
}

#[derive(Clone, Debug, Default)]
pub struct EngineOutput {
    pub consumed: bool,
    pub commit_text: String,
    pub preedit: String,
    pub bell: bool,
    pub notice: String,
}

pub const KEY_BACKSPACE: u16 = 0x33;
pub const KEY_ESCAPE: u16 = 0x35;
pub const KEY_RETURN: u16 = 0x24;
pub const KEY_ENTER_KP: u16 = 0x4C;
pub const KEY_SPACE: u16 = 0x31;
pub const KEY_TAB: u16 = 0x30;
pub const KEY_UP: u16 = 0x7E;
pub const KEY_DOWN: u16 = 0x7D;
pub const KEY_LEFT: u16 = 0x7B;
pub const KEY_RIGHT: u16 = 0x7C;
pub const KEY_PAGE_UP: u16 = 0x74;
pub const KEY_PAGE_DOWN: u16 = 0x79;

/// Calibrated weights combining spatial keystroke log-likelihood, lexical prior,
/// corpus N-gram context, and `Micro-RWKV-7` neural state log-probability.
#[derive(Clone, Copy, Debug)]
pub struct LmWeights {
    pub spatial_scale: f32,
    pub dict_prior_scale: f32,
    pub corpus_unigram_scale: f32,
    pub internal_bigram_scale: f32,
    pub bigram_scale: f32,
    pub trigram_scale: f32,
    pub cross_trigram_scale: f32,
    pub phrase_bonus: f32,
    pub neural_scale: f32,
}

impl LmWeights {
    pub const fn default_ngram() -> Self {
        Self {
            spatial_scale: 2.35,
            dict_prior_scale: 0.45,
            corpus_unigram_scale: 0.58,
            internal_bigram_scale: 0.35,
            bigram_scale: 0.95,
            trigram_scale: 1.00,
            cross_trigram_scale: 0.65,
            phrase_bonus: 0.65,
            neural_scale: 0.0,
        }
    }

    pub const fn default_neural() -> Self {
        Self {
            spatial_scale: 2.94,
            dict_prior_scale: 0.30,
            corpus_unigram_scale: 0.22,
            internal_bigram_scale: 0.28,
            bigram_scale: 0.65,
            trigram_scale: 0.65,
            cross_trigram_scale: 0.45,
            phrase_bonus: 0.65,
            neural_scale: 0.68,
        }
    }
}

impl Default for LmWeights {
    fn default() -> Self {
        Self::default_neural()
    }
}

pub struct WubiEngine {
    pub dicts: [Option<DictView>; 3],
    pub aux: Option<AuxView>,
    pub config: WubiConfig,
    pub user: UserStore,
    pub key_layout: KeyLayout,
    pub lm_weights: LmWeights,
    pub neural_tracker: NeuralContextTracker,

    pub ascii_mode: bool,
    raw_code: String,
    observations: Vec<KeyObs>,
    candidates: Vec<Candidate>,
    page: usize,
    last_committed: String,
    recent_context: Vec<char>,
    double_quote_open: bool,
    single_quote_open: bool,
}

impl Default for WubiEngine {
    fn default() -> Self {
        Self::new(WubiConfig::default())
    }
}

impl WubiEngine {
    pub fn new(config: WubiConfig) -> Self {
        Self {
            dicts: [None, None, None],
            aux: None,
            config,
            user: UserStore::default(),
            key_layout: KeyLayout::default(),
            lm_weights: LmWeights::default(),
            neural_tracker: NeuralContextTracker::default(),
            ascii_mode: false,
            raw_code: String::new(),
            observations: Vec::new(),
            candidates: Vec::new(),
            page: 0,
            last_committed: String::new(),
            recent_context: Vec::with_capacity(8),
            double_quote_open: false,
            single_quote_open: false,
        }
    }

    /// Explicitly set rolling CJK context (e.g. from surrounding text or offline evaluation).
    pub fn set_recent_context(&mut self, text: &str) {
        self.recent_context.clear();
        for ch in text.chars() {
            if is_cjk_char(ch) {
                self.recent_context.push(ch);
            } else {
                self.recent_context.clear();
            }
        }
        if let Some(nv) = self.aux.as_ref().and_then(|a| a.neural_view()) {
            // Feed the full active clause (up to 32 chars!) into Micro-RWKV-7 before truncating trigram window
            let clause: String = self
                .recent_context
                .iter()
                .skip(self.recent_context.len().saturating_sub(32))
                .collect();
            self.neural_tracker.set_context_str(&nv, &clause);
        }
        if self.recent_context.len() > 8 {
            let drain_n = self.recent_context.len() - 8;
            self.recent_context.drain(..drain_n);
        }
        self.last_committed = self.recent_context.iter().collect();
    }

    /// Incrementally append committed CJK text to rolling context (O(len(text)) instead of O(sentence)).
    pub fn append_recent_context(&mut self, text: &str) {
        let mut all_cjk = !text.is_empty();
        for ch in text.chars() {
            if is_cjk_char(ch) {
                self.recent_context.push(ch);
            } else {
                self.recent_context.clear();
                all_cjk = false;
            }
        }
        if let Some(nv) = self.aux.as_ref().and_then(|a| a.neural_view()) {
            if all_cjk {
                self.neural_tracker.commit_cjk_str(&nv, text);
            } else {
                self.neural_tracker.reset_to_bos(Some(&nv));
            }
        }
        if self.recent_context.len() > 8 {
            let drain_n = self.recent_context.len() - 8;
            self.recent_context.drain(..drain_n);
        }
        self.last_committed = self.recent_context.iter().collect();
    }

    /// Clear rolling sentence context (e.g. cursor jump or new text field).
    pub fn clear_context(&mut self) {
        self.recent_context.clear();
        self.last_committed.clear();
        let nv = self.aux.as_ref().and_then(|a| a.neural_view());
        self.neural_tracker.reset_to_bos(nv.as_ref());
    }

    /// Record a tapped idle-bar predicted word: updates personal word/char n-grams and advances
    /// rolling context immediately so chained predictions refresh without waiting on host text proxy lag.
    pub fn accept_prediction(&mut self, text: &str, timestamp_ms: u64) {
        if text.is_empty() {
            return;
        }
        let dict_idx = self.config.schema.slot_index();
        let prev = self.last_committed.clone();
        let _ = self.user.record_commit(
            &prev,
            text,
            timestamp_ms,
            false,
            self.config.auto_phrase_threshold,
            self.dicts[dict_idx].as_ref(),
        );
        self.last_committed = text.to_string();
        let mut all_cjk = !text.is_empty();
        for ch in text.chars() {
            if is_cjk_char(ch) {
                self.recent_context.push(ch);
            } else {
                self.recent_context.clear();
                all_cjk = false;
            }
        }
        if let Some(nv) = self.aux.as_ref().and_then(|a| a.neural_view()) {
            if all_cjk {
                self.neural_tracker.commit_cjk_str(&nv, text);
            } else {
                self.neural_tracker.reset_to_bos(Some(&nv));
            }
        }
        if self.recent_context.len() > 8 {
            let drain_n = self.recent_context.len() - 8;
            self.recent_context.drain(..drain_n);
        }
    }

    /// Lightweight idle next-word / next-char prediction reusing existing `WBAUX002` char N-grams,
    /// active dictionary phrase verification, and personal `UserStore` word bigrams (zero extra dict bytes).
    pub fn predict_next_words(&self, max_count: usize) -> Vec<String> {
        const STARTERS: [&str; 10] = [
            "我", "我们", "不是", "怎么", "可以", "这个", "其实", "但是", "今天", "现在",
        ];
        let limit = max_count.clamp(1, 16);
        if self.recent_context.is_empty() {
            return STARTERS
                .iter()
                .take(limit)
                .map(|s| (*s).to_string())
                .collect();
        }

        let p1 = *self.recent_context.last().unwrap();
        let p2 = if self.recent_context.len() >= 2 {
            Some(self.recent_context[self.recent_context.len() - 2])
        } else {
            None
        };
        let prev2_str: Option<String> = p2.map(|a| {
            let mut s = String::with_capacity(8);
            s.push(a);
            s.push(p1);
            s
        });

        struct PredCand {
            text: String,
            first_ch: char,
            score: f32,
            is_single: bool,
            is_completion: bool,
            is_personal: bool,
        }

        let mut pool = Vec::<PredCand>::with_capacity(64);

        // 1. Personal word bigrams from user's own typing history
        for (w, sc) in self
            .user
            .next_words_after(&self.recent_context, &self.last_committed)
        {
            if let Some(first_ch) = w.chars().next() {
                if prev2_str.as_deref() == Some(w.as_str()) {
                    continue;
                }
                pool.push(PredCand {
                    is_single: w.chars().count() == 1,
                    text: w,
                    first_ch,
                    score: sc,
                    is_completion: false,
                    is_personal: true,
                });
            }
        }

        // 2. Corpus char N-gram + dictionary-validated 2-char word expansion
        if let Some(ref aux) = self.aux {
            let dict = self.active_dict();
            // Gather candidate first characters `c1` after `(p2, p1)`
            let mut first_map = HashMap::<char, (f32, f32, f32)>::with_capacity(128);
            for (c1, bi) in aux.bigrams_after(p1) {
                if !is_cjk_char(c1) {
                    continue;
                }
                let uni = aux.unigram_prior(c1).unwrap_or(0.0);
                first_map.insert(c1, (uni, bi, 0.0));
            }
            if let Some(prev2) = p2 {
                for (c1, tri) in aux.trigrams_after(prev2, p1) {
                    if !is_cjk_char(c1) {
                        continue;
                    }
                    let entry = first_map.entry(c1).or_insert_with(|| {
                        (
                            aux.unigram_prior(c1).unwrap_or(0.0),
                            aux.bigram_boost(p1, c1),
                            0.0,
                        )
                    });
                    if tri > entry.2 {
                        entry.2 = tri;
                    }
                }
            }

            let nv_opt = aux
                .neural_view()
                .filter(|_| self.neural_tracker.is_ready());
            if let Some(ref nv) = nv_opt {
                for (c1, _lp) in nv.top_next_chars(&self.neural_tracker.active, 24) {
                    if is_cjk_char(c1) {
                        first_map.entry(c1).or_insert_with(|| {
                            (
                                aux.unigram_prior(c1).unwrap_or(5.0),
                                aux.bigram_boost(p1, c1),
                                p2.map(|prev2| aux.trigram_boost(prev2, p1, c1))
                                    .unwrap_or(0.0),
                            )
                        });
                    }
                }
            }

            // Check if `(p2, p1)` itself is a cohesive 2-char word (e.g. 情绪, 什么, 今天, 这个)
            let prev2_is_word = prev2_str
                .as_deref()
                .and_then(|s| dict.and_then(|d| d.contains_exact_word(s)))
                .is_some();

            let mut first_ranked: Vec<(char, f32, f32, f32, f32, Option<f32>)> = first_map
                .into_iter()
                .filter_map(|(c1, (uni, bi, tri))| {
                    let rwkv_lp1 = nv_opt
                        .as_ref()
                        .map(|nv| nv.score_next_char(&self.neural_tracker.active, c1));
                    if uni < 4.0 && tri < 1.0 && !rwkv_lp1.map(|lp| lp > -4.5).unwrap_or(false) {
                        return None;
                    }
                    // Avoid repeating same char unless strong trigram / neural (e.g. 哈哈)
                    if c1 == p1
                        && tri < 1.5
                        && bi < 3.5
                        && !rwkv_lp1.map(|lp| lp > -1.8).unwrap_or(false)
                    {
                        return None;
                    }
                    // When `(p2, p1)` is a 2-char word (like 情绪), discount `p1->c1` pairs that have
                    // zero trigram AND weak neural support (avoids homograph bleed like 光绪->年间).
                    let context_discount = if prev2_is_word && tri == 0.0 {
                        if rwkv_lp1.map(|lp| lp > -4.8).unwrap_or(false) {
                            0.15
                        } else {
                            1.45
                        }
                    } else {
                        0.0
                    };
                    let rwkv_boost = rwkv_lp1
                        .map(|lp| (lp + 6.0).clamp(-2.5, 5.5) * 0.90)
                        .unwrap_or(0.0);
                    // Conditional log-prob proxy: log P(c1 | clause) ≈ N-gram + Micro-RWKV-7 state
                    let cond = 1.00 * uni + 0.78 * bi + 1.55 * tri + rwkv_boost - context_discount;
                    Some((c1, cond, uni, bi, tri, rwkv_lp1))
                })
                .collect();
            first_ranked.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(core::cmp::Ordering::Equal));
            first_ranked.truncate(18);

            let mut strong_phrase_for_c1 = HashMap::<char, f32>::new();

            for &(c1, cond1, uni1, bi1, tri1, rwkv_lp1) in first_ranked.iter().take(14) {
                // Determine whether `c1` completes the current in-progress 2-char or 3-char word
                // (e.g. 不知->道, 小红->书, 大模->型, 没问->题, 性价->比, 绷不->住, 输入->法)
                let mut is_tri_comp = false;
                let mut is_bi_comp = false;
                let mut comp_bonus = 0.0f32;
                let strong_rwkv_comp = rwkv_lp1.map(|lp| lp > -1.35).unwrap_or(false);
                if let Some(prev2) = p2 {
                    let mut s3 = String::with_capacity(12);
                    s3.push(prev2);
                    s3.push(p1);
                    s3.push(c1);
                    let in_dict_3 = dict.and_then(|d| d.contains_exact_word(&s3)).is_some();
                    if in_dict_3 || strong_rwkv_comp || (tri1 >= 0.35 && bi1 >= 1.0) {
                        is_tri_comp = true;
                        comp_bonus = if in_dict_3 || strong_rwkv_comp {
                            3.45
                        } else {
                            (1.30 + 0.70 * tri1).min(2.90)
                        };
                    }
                } else if let Some(d) = dict {
                    let mut s2 = String::with_capacity(8);
                    s2.push(p1);
                    s2.push(c1);
                    if d.contains_exact_word(&s2).is_some() && (bi1 >= 2.6 || strong_rwkv_comp) {
                        is_bi_comp = true;
                        comp_bonus = 1.95;
                    }
                }
                let is_comp = is_tri_comp || is_bi_comp;

                // Single-char candidate
                pool.push(PredCand {
                    text: c1.to_string(),
                    first_ch: c1,
                    score: cond1 + comp_bonus,
                    is_single: true,
                    is_completion: is_comp,
                    is_personal: false,
                });

                // If `c1` strongly completes a 3-char word `(p2, p1, c1)` (like 不知->道, 小红->书,
                // 性价->比, 绷不->住), do NOT glue `c1` onto a new word (`道德`/`书记`/`比较`/`住房`)!
                if is_tri_comp && (tri1 >= 0.35 || comp_bonus >= 3.0) {
                    continue;
                }

                // Expand c1 -> c2 (only high-confidence real 2-char Chinese words)
                let mut sec_map = HashMap::<char, (f32, f32)>::with_capacity(48);
                for (c2, bi12) in aux.bigrams_after(c1) {
                    if !is_cjk_char(c2) || bi12 < 1.6 {
                        continue;
                    }
                    sec_map.insert(c2, (bi12, 0.0));
                }
                for (c2, tri12) in aux.trigrams_after(p1, c1) {
                    if !is_cjk_char(c2) {
                        continue;
                    }
                    let e = sec_map
                        .entry(c2)
                        .or_insert_with(|| (aux.bigram_boost(c1, c2), 0.0));
                    if tri12 > e.1 {
                        e.1 = tri12;
                    }
                }

                let mut sec_ranked: Vec<(char, f32, f32, f32, f32)> = sec_map
                    .into_iter()
                    .filter_map(|(c2, (bi12, tri12))| {
                        let uni2 = aux.unigram_prior(c2).unwrap_or(0.0);
                        if uni2 < 4.5 && tri12 < 1.5 {
                            return None;
                        }
                        if bi12 < 1.6 && tri12 < 1.3 {
                            return None;
                        }
                        let raw = 0.40 * bi12 + 0.70 * tri12 + 0.32 * uni2;
                        Some((c2, raw, uni2, bi12, tri12))
                    })
                    .collect();
                sec_ranked.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(core::cmp::Ordering::Equal));

                let mut emitted_for_c1 = 0usize;
                for (c2, raw2, _uni2, bi12, tri12) in sec_ranked.into_iter().take(8) {
                    let mut w2 = String::with_capacity(8);
                    w2.push(c1);
                    w2.push(c2);
                    // Never repeat the exact 2-char word just typed (e.g. 我们 -> 我们)
                    if prev2_str.as_deref() == Some(w2.as_str()) {
                        continue;
                    }
                    // Skip pure Chinese numeral pairs (二十/三十/十五 from historical dates) unless context is numeric
                    if is_numeral_pair(c1, c2) && !is_numeral_char(p1) {
                        continue;
                    }
                    let dict_wt = dict.and_then(|d| d.contains_exact_word(&w2));
                    let Some(wt) = dict_wt else {
                        // Allow modern non-dict 2-char slang ONLY with very strong trigram + bigram support
                        if tri12 >= 1.6 && bi12 >= 2.8 {
                            let sc2 = cond1 + raw2 - 3.10;
                            pool.push(PredCand {
                                text: w2,
                                first_ch: c1,
                                score: sc2,
                                is_single: false,
                                is_completion: false,
                                is_personal: false,
                            });
                            emitted_for_c1 += 1;
                            if emitted_for_c1 >= 2 {
                                break;
                            }
                        }
                        continue;
                    };
                    // Require genuinely common dictionary words (avoid obscure 0-weight compound entries)
                    if wt < 50_000 && tri12 < 1.0 {
                        continue;
                    }
                    let rwkv_w2 = nv_opt
                        .as_ref()
                        .map(|nv| nv.score_phrase_fast(&self.neural_tracker.active, &w2));
                    // If `c1` is a standalone common char (会/是/有/后/分) and `(p1,c1,c2)` has ZERO
                    // trigram evidence and weak neural phrase support, don't hallucinate unrelated compounds!
                    if is_standalone_common_char(c1)
                        && tri12 == 0.0
                        && !rwkv_w2.map(|lp| lp > -4.2).unwrap_or(false)
                    {
                        continue;
                    }

                    // Check if `p1+c1+c2` forms a 3-char word (e.g. `不` -> `知道`, `小` -> `红书`, `大` -> `模型`)
                    let mut comp3_bonus = 0.0f32;
                    if let Some(d) = dict {
                        let mut s3 = String::with_capacity(12);
                        s3.push(p1);
                        s3.push(c1);
                        s3.push(c2);
                        if d.contains_exact_word(&s3).is_some() {
                            comp3_bonus = 1.40;
                        }
                    }

                    let tri_ground_bonus = if tri12 > 0.0 {
                        0.85
                    } else if rwkv_w2.map(|lp| lp > -4.8).unwrap_or(false) {
                        0.35
                    } else {
                        -0.65
                    };
                    let rwkv_w2_boost = rwkv_w2
                        .map(|lp| (lp + 5.8).clamp(-1.8, 4.5) * 0.85)
                        .unwrap_or(0.0);
                    let freq_bonus = (((wt as f32) + 100.0).ln() - 11.0).clamp(-1.0, 2.2) * 0.40;
                    let split_penalty = if is_bi_comp && comp3_bonus == 0.0 && tri12 < 0.8 {
                        1.25
                    } else {
                        0.0
                    };
                    let sc2 = cond1 + raw2 + tri_ground_bonus + rwkv_w2_boost + freq_bonus + comp3_bonus - 3.10 - split_penalty;
                    if bi12 >= 3.4 && sc2 > cond1 {
                        let entry = strong_phrase_for_c1.entry(c1).or_insert(f32::NEG_INFINITY);
                        if sc2 > *entry {
                            *entry = sc2;
                        }
                    }
                    pool.push(PredCand {
                        text: w2,
                        first_ch: c1,
                        score: sc2,
                        is_single: false,
                        is_completion: comp3_bonus > 0.0,
                        is_personal: false,
                    });
                    emitted_for_c1 += 1;
                    if emitted_for_c1 >= 3 {
                        break;
                    }
                }
                let _ = uni1;
            }

            // Penalize bare orphan bound-morpheme chars (e.g. `觉` when `觉得` beat it strongly)
            for item in &mut pool {
                if item.is_single && !item.is_completion && !item.is_personal {
                    if let Some(&best_w2) = strong_phrase_for_c1.get(&item.first_ch) {
                        if best_w2 > item.score + 0.25 && !is_standalone_common_char(item.first_ch) {
                            item.score -= 3.2;
                        }
                    }
                }
            }
        }

        pool.sort_by(|a, b| {
            b.score
                .partial_cmp(&a.score)
                .unwrap_or(core::cmp::Ordering::Equal)
        });

        let mut result = Vec::<String>::with_capacity(limit);
        let mut seen = HashSet::<String>::new();
        let mut per_first = HashMap::<char, usize>::new();

        for cand in pool {
            if seen.contains(&cand.text) {
                continue;
            }
            let fc = per_first.get(&cand.first_ch).copied().unwrap_or(0);
            if fc >= 2 && !cand.is_personal {
                continue;
            }
            seen.insert(cand.text.clone());
            *per_first.entry(cand.first_ch).or_insert(0) += 1;
            result.push(cand.text);
            if result.len() >= limit {
                break;
            }
        }

        if result.len() < limit {
            for &s in &STARTERS {
                if seen.insert(s.to_string()) {
                    result.push(s.to_string());
                    if result.len() >= limit {
                        break;
                    }
                }
            }
        }
        result
    }

    pub fn load_dict(&mut self, schema: WubiSchema, dict: DictView) {
        let slot = schema.slot_index();
        self.dicts[slot] = Some(dict);
        if self.config.schema == schema {
            if let Some(ref d) = self.dicts[slot] {
                self.user.reindex_phrases(d);
            }
            if !self.raw_code.is_empty() {
                self.rebuild_candidates();
            }
        }
    }

    pub fn set_aux(&mut self, aux: AuxView) {
        if let Some(nv) = aux.neural_view() {
            self.neural_tracker.init_with_model(&nv);
            self.lm_weights = LmWeights::default_neural();
        } else {
            self.neural_tracker = NeuralContextTracker::default();
            self.lm_weights = LmWeights::default_ngram();
        }
        self.aux = Some(aux);
        if !self.raw_code.is_empty() {
            self.rebuild_candidates();
        }
    }

    pub fn active_dict(&self) -> Option<&DictView> {
        self.dicts[self.config.schema.slot_index()].as_ref()
    }

    pub fn set_config(&mut self, new_config: WubiConfig) {
        let schema_changed = self.config.schema != new_config.schema;
        self.config = new_config;
        if schema_changed {
            let slot = self.config.schema.slot_index();
            if let Some(ref d) = self.dicts[slot] {
                self.user.reindex_phrases(d);
            }
        }
        if !self.raw_code.is_empty() {
            self.rebuild_candidates();
        }
    }

    pub fn set_schema(&mut self, schema: WubiSchema) {
        if self.config.schema != schema {
            self.config.schema = schema;
            let slot = self.config.schema.slot_index();
            if let Some(ref d) = self.dicts[slot] {
                self.user.reindex_phrases(d);
            }
            self.clear_composition();
        }
    }

    #[inline]
    pub fn raw_code(&self) -> &str {
        &self.raw_code
    }

    #[inline]
    pub fn is_composing(&self) -> bool {
        !self.raw_code.is_empty()
    }

    #[inline]
    pub fn all_candidates(&self) -> &[Candidate] {
        &self.candidates
    }

    #[inline]
    pub fn current_page(&self) -> usize {
        self.page
    }

    pub fn total_pages(&self) -> usize {
        let ps = (self.config.page_size as usize).max(1);
        if self.candidates.is_empty() {
            0
        } else {
            (self.candidates.len() + ps - 1) / ps
        }
    }

    pub fn page_candidates(&self) -> &[Candidate] {
        let ps = (self.config.page_size as usize).max(1);
        let start = self.page * ps;
        if start >= self.candidates.len() {
            &[]
        } else {
            let end = (start + ps).min(self.candidates.len());
            &self.candidates[start..end]
        }
    }

    pub fn clear_composition(&mut self) {
        self.raw_code.clear();
        self.observations.clear();
        self.candidates.clear();
        self.page = 0;
    }

    /// Toggle between Chinese Wubi mode and English ASCII mode (e.g. Shift tap).
    pub fn toggle_ascii_mode(&mut self) -> EngineOutput {
        let mut out = EngineOutput {
            consumed: true,
            ..Default::default()
        };
        if !self.raw_code.is_empty() {
            match self.config.shift_toggle_mode {
                ShiftToggleMode::CommitCode => {
                    out.commit_text = self.raw_code.clone();
                }
                ShiftToggleMode::CommitFirst => {
                    out.commit_text = self
                        .candidates
                        .first()
                        .map(|c| c.text.clone())
                        .unwrap_or_else(|| self.raw_code.clone());
                }
                ShiftToggleMode::Clear => {}
            }
            self.clear_composition();
            self.user.break_single_burst();
            self.clear_context();
        }
        self.ascii_mode = !self.ascii_mode;
        if self.ascii_mode {
            self.clear_context();
        }
        out
    }

    /// Explicitly select candidate at index `rel_idx` (`0..page_size`) on the current page.
    pub fn select_page_candidate(&mut self, rel_idx: usize, timestamp_ms: u64) -> Option<EngineOutput> {
        let ps = (self.config.page_size as usize).max(1);
        let abs_idx = self.page * ps + rel_idx;
        self.select_abs_candidate(abs_idx, timestamp_ms)
    }

    pub fn select_abs_candidate(&mut self, abs_idx: usize, timestamp_ms: u64) -> Option<EngineOutput> {
        let cand = self.candidates.get(abs_idx)?.clone();
        let mut notice = String::new();
        self.finalize_commit(&cand.text, Some(cand.matched_code), timestamp_ms, &mut notice);
        self.clear_composition();
        Some(EngineOutput {
            consumed: true,
            commit_text: cand.text,
            preedit: String::new(),
            bell: false,
            notice,
        })
    }

    pub fn page_prev(&mut self) -> bool {
        if self.page > 0 {
            self.page -= 1;
            true
        } else {
            false
        }
    }

    pub fn page_next(&mut self) -> bool {
        if self.page + 1 < self.total_pages() {
            self.page += 1;
            true
        } else {
            false
        }
    }

    /// 26-bit mask (`bit i` = `'a' + i`) of letters valid as the next Wubi keystroke.
    /// Used by iOS touch hit-testing to dynamically expand valid next-key boundaries.
    pub fn valid_next_mask(&self) -> u32 {
        const ALL_26: u32 = 0x03FF_FFFF;
        if self.ascii_mode {
            return ALL_26;
        }
        let bytes = self.raw_code.as_bytes();
        if bytes.is_empty() || bytes.len() >= 4 || bytes.contains(&b'z') {
            return ALL_26;
        }
        let mut mask = self.user.valid_next_letters_mask(bytes);
        if let Some(dict) = self.active_dict() {
            mask |= dict.valid_next_letters_mask(bytes, self.config.enable_rare_charset);
        }
        // If current prefix has no exact continuations at all (e.g. already a typo), stay neutral.
        if mask == 0 {
            return ALL_26;
        }
        if self.config.z_omnipotent {
            mask |= 1u32 << 25;
        }
        mask
    }

    /// 26-element continuous touch hitbox weight vector (`0` = dead key, `100` = neutral valid key,
    /// `50..=180` = `Micro-RWKV-7` context-weighted valid key).
    /// Powers Key #1 predictive gutter bias AND Keys #2..#4 valid-vs-valid gutter disambiguation!
    pub fn next_key_priors(&self) -> [u8; 26] {
        let mut out = [100u8; 26];
        if self.ascii_mode || !self.config.typo.enabled {
            return out;
        }
        let bytes = self.raw_code.as_bytes();
        if bytes.len() >= 4 || bytes.contains(&b'z') {
            return out;
        }

        // Case 1: Key #1 (`raw_code` is empty) — use cached `Micro-RWKV-7` first-stroke head!
        if bytes.is_empty() {
            if self.neural_tracker.is_ready() {
                // Uniform log-prob across 25 Wubi keys ('a'..'y') is ln(1/25) = -3.2189
                for idx in 0..25usize {
                    let lp = self.neural_tracker.active.key1_logp[idx];
                    let delta = lp - (-3.2189f32);
                    out[idx] = (100.0 + 20.0 * delta).round().clamp(72.0, 168.0) as u8;
                }
            }
            return out;
        }

        // Case 2: Keys #2..#4 (`1 <= len <= 3`) — combine dictionary validity with RWKV context priors!
        let mask = self.valid_next_mask();
        if mask == 0x03FF_FFFF || mask == 0 {
            return out;
        }
        for idx in 0..26usize {
            if (mask & (1u32 << idx)) == 0 {
                out[idx] = 0;
            }
        }

        if let (Some(nv), Some(dict)) = (
            self.aux.as_ref().and_then(|a| a.neural_view()),
            self.active_dict(),
        ) {
            if self.neural_tracker.is_ready() {
                let best_conts =
                    dict.best_continuation_per_letter(bytes, self.config.enable_rare_charset);
                let mut raw_s = [f32::NEG_INFINITY; 25];
                let mut sum_s = 0.0f32;
                let mut cnt_s = 0usize;

                for idx in 0..25usize {
                    if out[idx] == 0 {
                        continue;
                    }
                    if let Some(e) = best_conts[idx] {
                        let ns = nv.score_phrase_fast(&self.neural_tracker.active, e.text);
                        let dp = 0.16 * ((e.weight as f32) + 50.0).ln();
                        let s = ns + dp;
                        raw_s[idx] = s;
                        sum_s += s;
                        cnt_s += 1;
                    }
                }
                if cnt_s >= 2 {
                    let mean_s = sum_s / (cnt_s as f32);
                    for idx in 0..25usize {
                        if raw_s[idx].is_finite() {
                            out[idx] = (100.0 + 15.0 * (raw_s[idx] - mean_s))
                                .round()
                                .clamp(54.0, 176.0) as u8;
                        }
                    }
                }
            }
        }
        out
    }

    /// Push a touchscreen letter tap with view/normalized coordinates `(x, y)` (used by iOS keyboard & touch tests).
    pub fn push_touch_letter(
        &mut self,
        reported_ch: u8,
        view_x: f32,
        view_y: f32,
        is_normalized: bool,
        timestamp_ms: u64,
    ) -> EngineOutput {
        let (nx, ny) = if is_normalized {
            (view_x, view_y)
        } else {
            self.key_layout.view_to_norm(view_x, view_y)
        };
        let reported_lower = reported_ch.to_ascii_lowercase();
        let adapted_ch = if !is_normalized && reported_lower.is_ascii_lowercase() {
            // View-space UI hit-testing (`IOSKeyboardLayoutEngine.hitTest`) already resolved
            // rectangular keycaps, side margins, ergonomic thumb Y-bias, and `valid_next_mask` —
            // and showed the callout bubble for `reported_lower`. Always keep `reported_lower` as
            // the primary observation while still storing exact `(nx, ny)` in `KeyObs::touch` for
            // 2D Gaussian typo rescue (`generate_hypotheses`), so outer-margin/corner taps (e.g.
            // beside `z` or `m`) never silently mutate away from what the callout displayed.
            reported_lower
        } else if self.config.typo.enabled && self.config.typo.touch_hitbox_adapt {
            let nearest = self
                .key_layout
                .nearest_key(nx, ny, &self.user.touch_profile, true);
            let mask = self.valid_next_mask();
            if nearest != reported_lower
                && reported_lower.is_ascii_lowercase()
                && mask != 0x03FF_FFFF
            {
                let rep_bit = 1u32 << (reported_lower - b'a');
                let near_bit = 1u32 << (nearest - b'a');
                if (mask & rep_bit) != 0 && (mask & near_bit) == 0 {
                    let (cx, cy) = self.key_layout.center_of(reported_lower);
                    let (dx, dy) = self.user.touch_profile.offset_for(reported_lower);
                    let d2 = (nx - (cx + dx)).powi(2) + (ny - (cy + dy)).powi(2);
                    if d2 <= 0.66 * 0.66 {
                        reported_lower
                    } else {
                        nearest
                    }
                } else {
                    nearest
                }
            } else {
                nearest
            }
        } else {
            reported_lower
        };
        let obs = KeyObs::touch(adapted_ch, nx, ny, timestamp_ms);
        self.push_code_observation(obs)
    }

    /// Unified macOS / physical keyboard event entry point.
    pub fn handle_key_event(
        &mut self,
        keycode: u16,
        ch: Option<char>,
        has_cmd_or_ctrl: bool,
        timestamp_ms: u64,
    ) -> EngineOutput {
        // Shortcut: Ctrl + '=' manually registers last 2..4 committed chars as a custom phrase!
        if has_cmd_or_ctrl {
            if ch == Some('=') && !self.ascii_mode {
                if let Some(out) = self.manual_create_phrase_from_recent() {
                    return out;
                }
            }
            return EngineOutput::default();
        }

        if self.ascii_mode {
            return EngineOutput::default();
        }

        // Handle special navigation / editing keys when composing
        match keycode {
            KEY_BACKSPACE => {
                if self.raw_code.is_empty() {
                    self.user.break_single_burst();
                    self.recent_context.clear();
                    let nv = self.aux.as_ref().and_then(|a| a.neural_view());
                    self.neural_tracker.pop_commit_or_reset(nv.as_ref());
                    return EngineOutput::default();
                }
                self.raw_code.pop();
                self.observations.pop();
                self.page = 0;
                if self.raw_code.is_empty() {
                    self.candidates.clear();
                } else {
                    self.rebuild_candidates();
                }
                return EngineOutput {
                    consumed: true,
                    preedit: self.raw_code.clone(),
                    ..Default::default()
                };
            }
            KEY_ESCAPE => {
                if self.raw_code.is_empty() {
                    return EngineOutput::default();
                }
                self.clear_composition();
                return EngineOutput {
                    consumed: true,
                    ..Default::default()
                };
            }
            KEY_RETURN | KEY_ENTER_KP => {
                if self.raw_code.is_empty() {
                    self.user.break_single_burst();
                    self.clear_context();
                    return EngineOutput::default();
                }
                let raw = self.raw_code.clone();
                self.clear_composition();
                self.user.break_single_burst();
                self.clear_context();
                return EngineOutput {
                    consumed: true,
                    commit_text: raw,
                    ..Default::default()
                };
            }
            KEY_SPACE => {
                if self.raw_code.is_empty() {
                    self.user.break_single_burst();
                    self.clear_context();
                    return EngineOutput::default();
                }
                if let Some(out) = self.select_page_candidate(0, timestamp_ms) {
                    return out;
                }
                // Empty code on Space: clear or bell
                let bell = true;
                if self.config.fourth_empty_behavior == FourthEmptyBehavior::Clear {
                    self.clear_composition();
                }
                return EngineOutput {
                    consumed: true,
                    preedit: self.raw_code.clone(),
                    bell,
                    ..Default::default()
                };
            }
            KEY_UP | KEY_PAGE_UP => {
                if !self.raw_code.is_empty() {
                    self.page_prev();
                    return EngineOutput {
                        consumed: true,
                        preedit: self.raw_code.clone(),
                        ..Default::default()
                    };
                }
                return EngineOutput::default();
            }
            KEY_DOWN | KEY_PAGE_DOWN | KEY_TAB => {
                if !self.raw_code.is_empty() {
                    self.page_next();
                    return EngineOutput {
                        consumed: true,
                        preedit: self.raw_code.clone(),
                        ..Default::default()
                    };
                }
                return EngineOutput::default();
            }
            _ => {}
        }

        let Some(c) = ch else {
            return EngineOutput::default();
        };

        // Lowercase letter 'a'..='z': core Wubi composition!
        if c.is_ascii_lowercase() {
            let obs = KeyObs::physical(c as u8, timestamp_ms);
            return self.push_code_observation(obs);
        }

        // Uppercase letter 'A'..='Z': commit current candidate #1 (if composing) and pass/commit uppercase
        if c.is_ascii_uppercase() {
            if self.raw_code.is_empty() {
                self.user.break_single_burst();
                self.clear_context();
                return EngineOutput::default();
            }
            let mut committed = String::new();
            let mut notice = String::new();
            if let Some(first) = self.candidates.first().cloned() {
                self.finalize_commit(&first.text, Some(first.matched_code), timestamp_ms, &mut notice);
                committed.push_str(&first.text);
            }
            self.clear_composition();
            self.user.break_single_burst();
            self.clear_context();
            committed.push(c);
            return EngineOutput {
                consumed: true,
                commit_text: committed,
                notice,
                ..Default::default()
            };
        }

        // While composing: digits 1..=9, paging `-`/`=`/`[`/`]`, quick `;`/`'` select
        if !self.raw_code.is_empty() {
            if ('1'..='9').contains(&c) {
                let idx = (c as u8 - b'1') as usize;
                if idx < self.config.page_size as usize {
                    if let Some(out) = self.select_page_candidate(idx, timestamp_ms) {
                        return out;
                    }
                }
                return EngineOutput {
                    consumed: true,
                    preedit: self.raw_code.clone(),
                    bell: true,
                    ..Default::default()
                };
            }
            if c == '-' || c == '[' {
                self.page_prev();
                return EngineOutput {
                    consumed: true,
                    preedit: self.raw_code.clone(),
                    ..Default::default()
                };
            }
            if c == '=' || c == ']' {
                self.page_next();
                return EngineOutput {
                    consumed: true,
                    preedit: self.raw_code.clone(),
                    ..Default::default()
                };
            }
            if self.config.semicolon_quote_select && (c == ';' || c == '\'') {
                let idx = if c == ';' { 1 } else { 2 };
                if let Some(out) = self.select_page_candidate(idx, timestamp_ms) {
                    return out;
                }
            }
        }

        // Chinese smart punctuation (commits active candidate #1 first if composing!)
        if self.config.smart_punctuation {
            if let Some(mapped) = self.map_chinese_punctuation(c) {
                let mut text = String::new();
                let mut notice = String::new();
                if !self.raw_code.is_empty() {
                    if let Some(first) = self.candidates.first().cloned() {
                        self.finalize_commit(
                            &first.text,
                            Some(first.matched_code),
                            timestamp_ms,
                            &mut notice,
                        );
                        text.push_str(&first.text);
                    }
                    self.clear_composition();
                }
                self.user.break_single_burst();
                self.clear_context();
                text.push_str(&mapped);
                return EngineOutput {
                    consumed: true,
                    commit_text: text,
                    notice,
                    ..Default::default()
                };
            }
        }

        EngineOutput::default()
    }

    fn push_code_observation(&mut self, obs: KeyObs) -> EngineOutput {
        let mut commit_prefix = String::new();
        let mut notice = String::new();

        let is_z_pinyin_mode = self.config.z_omnipotent
            && self.raw_code.starts_with('z')
            && !self.raw_code.starts_with("zz");
        let max_len = if is_z_pinyin_mode { 7 } else { 4 };

        // Fifth-code push-commit (第五码自动顶字上屏)!
        if self.raw_code.len() >= max_len {
            if !is_z_pinyin_mode && self.config.fifth_code_push_commit {
                if let Some(first) = self.candidates.first().cloned() {
                    self.finalize_commit(
                        &first.text,
                        Some(first.matched_code),
                        obs.timestamp_ms,
                        &mut notice,
                    );
                    commit_prefix.push_str(&first.text);
                }
                self.clear_composition();
            } else {
                return EngineOutput {
                    consumed: true,
                    preedit: self.raw_code.clone(),
                    bell: true,
                    ..Default::default()
                };
            }
        }

        self.raw_code.push(obs.ch as char);
        self.observations.push(obs);
        self.page = 0;
        self.rebuild_candidates();

        // Check 4th-code behaviors (ONLY for standard 4-letter Wubi codes, not z+pinyin)!
        let now_z_pinyin = self.config.z_omnipotent
            && self.raw_code.starts_with('z')
            && !self.raw_code.starts_with("zz");

        if !now_z_pinyin && self.raw_code.len() == 4 {
            if self.candidates.is_empty() {
                // Truly empty 4-letter code (even typo rescue found no high-confidence match)
                match self.config.fourth_empty_behavior {
                    FourthEmptyBehavior::Block => {
                        self.raw_code.pop();
                        self.observations.pop();
                        self.rebuild_candidates();
                        return EngineOutput {
                            consumed: true,
                            commit_text: commit_prefix,
                            preedit: self.raw_code.clone(),
                            bell: true,
                            notice,
                        };
                    }
                    FourthEmptyBehavior::Clear => {
                        self.clear_composition();
                        return EngineOutput {
                            consumed: true,
                            commit_text: commit_prefix,
                            preedit: String::new(),
                            bell: true,
                            notice,
                        };
                    }
                }
            } else if self.config.fourth_code_auto_commit && self.should_auto_commit_fourth() {
                let first = self.candidates[0].clone();
                self.finalize_commit(
                    &first.text,
                    Some(first.matched_code),
                    obs.timestamp_ms,
                    &mut notice,
                );
                commit_prefix.push_str(&first.text);
                self.clear_composition();
                return EngineOutput {
                    consumed: true,
                    commit_text: commit_prefix,
                    preedit: String::new(),
                    bell: false,
                    notice,
                };
            }
        }

        EngineOutput {
            consumed: true,
            commit_text: commit_prefix,
            preedit: self.raw_code.clone(),
            bell: false,
            notice,
        }
    }

    fn should_auto_commit_fourth(&self) -> bool {
        if self.raw_code.contains('z') {
            return false;
        }
        // Count exact candidates vs typo-corrected candidates
        let exact_cands: Vec<&Candidate> = self.candidates.iter().filter(|c| c.is_exact).collect();
        if exact_cands.len() == 1 {
            // Only auto-commit when #1 IS that unique exact candidate!
            if self.candidates[0].is_exact {
                return true;
            }
        }
        // If #1 is a typo-corrected candidate, respect `suppress_auto_commit_on_correction`!
        if !self.candidates[0].is_exact && !self.config.typo.suppress_auto_commit_on_correction {
            return self.candidates.len() == 1 || self.candidates[0].confidence >= 0.94;
        }
        false
    }

    fn finalize_commit(
        &mut self,
        text: &str,
        matched_code: Option<PackedCode>,
        timestamp_ms: u64,
        notice: &mut String,
    ) {
        // 1. Update personal touch-region adaptive offsets if touch observations match `matched_code`!
        if self.config.typo.enabled && self.config.typo.touch_hitbox_adapt {
            if let Some(code) = matched_code {
                let (code_bytes, code_len) = code.to_bytes_buf();
                if code_len == self.observations.len() {
                    for (i, obs) in self.observations.iter().enumerate() {
                        if obs.has_touch {
                            let target_key = code_bytes[i];
                            let (cx, cy) = self.key_layout.center_of(target_key);
                            self.user
                                .touch_profile
                                .observe(target_key, obs.norm_x - cx, obs.norm_y - cy);
                            self.user.dirty = true;
                        }
                    }
                }
            }
        }

        // 2. Update personal history & consecutive auto-phrase learning
        let dict_idx = self.config.schema.slot_index();
        let prev = self.last_committed.clone();
        let learned = self.user.record_commit(
            &prev,
            text,
            timestamp_ms,
            self.config.auto_phrase,
            self.config.auto_phrase_threshold,
            self.dicts[dict_idx].as_ref(),
        );
        if let Some(new_word) = learned {
            if let Some(ref d) = self.dicts[dict_idx] {
                if let Some(c) = d.encode_phrase(&new_word) {
                    *notice = format!("自动成词：{} ({})", new_word, c.as_string());
                }
            }
        }
        self.last_committed = text.to_string();
        let mut all_cjk = !text.is_empty();
        for ch in text.chars() {
            if is_cjk_char(ch) {
                self.recent_context.push(ch);
            } else {
                self.recent_context.clear();
                all_cjk = false;
            }
        }
        if let Some(nv) = self.aux.as_ref().and_then(|a| a.neural_view()) {
            if all_cjk {
                self.neural_tracker.commit_cjk_str(&nv, text);
            } else {
                self.neural_tracker.reset_to_bos(Some(&nv));
            }
        }
        if self.recent_context.len() > 8 {
            let drain_n = self.recent_context.len() - 8;
            self.recent_context.drain(..drain_n);
        }
    }

    fn manual_create_phrase_from_recent(&mut self) -> Option<EngineOutput> {
        let dict_idx = self.config.schema.slot_index();
        let d = self.dicts[dict_idx].as_ref()?;
        if self.last_committed.chars().count() >= 2 {
            let phrase = self.last_committed.clone();
            let code = self.user.add_phrase(&phrase, false, Some(d))?;
            return Some(EngineOutput {
                consumed: true,
                notice: format!("已收录词条：{} ({})", phrase, code.as_string()),
                ..Default::default()
            });
        }
        None
    }

    fn map_chinese_punctuation(&mut self, c: char) -> Option<String> {
        let s = match c {
            ',' => "，",
            '.' => "。",
            '?' => "？",
            '!' => "！",
            ':' => "：",
            ';' => "；",
            '(' => "（",
            ')' => "）",
            '[' => "【",
            ']' => "】",
            '<' => "《",
            '>' => "》",
            '\\' => "、",
            '^' => "……",
            '_' => "——",
            '$' => "￥",
            '"' => {
                self.double_quote_open = !self.double_quote_open;
                if self.double_quote_open {
                    "“"
                } else {
                    "”"
                }
            }
            '\'' => {
                self.single_quote_open = !self.single_quote_open;
                if self.single_quote_open {
                    "‘"
                } else {
                    "’"
                }
            }
            _ => return None,
        };
        Some(s.to_string())
    }

    // ========================================================================
    // Candidate Assembly & Bayesian Spatial + N-gram Ranking
    // ========================================================================

    pub fn rebuild_candidates(&mut self) {
        self.candidates.clear();
        if self.raw_code.is_empty() {
            return;
        }
        let slot = self.config.schema.slot_index();
        if self.dicts[slot].is_none() {
            return;
        }

        // Branch 1: `z` omnipotent mode (z-prompt, zz-symbols, z+pinyin reverse lookup)
        if self.config.z_omnipotent && self.raw_code.starts_with('z') {
            self.build_z_mode_candidates(slot);
            return;
        }

        // Branch 2: `z` wildcard at positions 2..=4 (e.g. `khz`, `tznt`)
        if self.config.z_omnipotent && self.raw_code.contains('z') {
            self.build_wildcard_candidates(slot);
            return;
        }

        // Branch 3: Standard Wubi 1..=4 letters + Bayesian Spatial/Lexical/History Typo Decoder
        self.build_standard_and_typo_candidates(slot);
    }

    fn build_z_mode_candidates(&mut self, slot: usize) {
        let dict = self.dicts[slot].as_ref().unwrap();
        if self.raw_code == "z" {
            for (sym, desc) in [
                ("，", "输拼音反查五笔 · zz特殊符号"),
                ("。", "句号"),
                ("？", "问号"),
                ("！", "叹号"),
                ("……", "省略号"),
                ("——", "破折号"),
                ("、", "顿号"),
            ] {
                self.candidates.push(Candidate {
                    text: sym.to_string(),
                    matched_code: PackedCode::from_ascii("z").unwrap_or_default(),
                    comment: desc.to_string(),
                    badge: CandidateBadge::PinyinLookup,
                    confidence: 1.0,
                    is_exact: true,
                });
            }
            return;
        }

        let mut seen = HashSet::<String>::new();

        // Check `zz*` symbol dictionary entries first if code <= 4
        if self.raw_code.starts_with("zz") && self.raw_code.len() <= 4 {
            if let Some(pc) = PackedCode::from_ascii(&self.raw_code) {
                for e in dict.lookup_exact(pc, true) {
                    if seen.insert(e.text.to_string()) {
                        self.candidates.push(Candidate {
                            text: e.text.to_string(),
                            matched_code: pc,
                            comment: if (e.flags & ENTRY_FLAG_SYMBOL) != 0 {
                                "符号".to_string()
                            } else {
                                pc.as_string()
                            },
                            badge: CandidateBadge::None,
                            confidence: 1.0,
                            is_exact: true,
                        });
                    }
                }
                for e in dict.lookup_longer_prefix(pc, 24, true) {
                    if seen.insert(e.text.to_string()) {
                        self.candidates.push(Candidate {
                            text: e.text.to_string(),
                            matched_code: e.code,
                            comment: e.code.as_string(),
                            badge: CandidateBadge::None,
                            confidence: 0.9,
                            is_exact: true,
                        });
                    }
                }
            }
        }

        // Pinyin reverse lookup (`z` + pinyin)
        if let Some(ref aux) = self.aux {
            let py_query = &self.raw_code.as_bytes()[1..];
            if !py_query.is_empty() && py_query.len() <= 6 {
                for (ch, _wt, py_disp, _exact) in aux.lookup_pinyin(py_query, 36) {
                    let s = ch.to_string();
                    if !seen.insert(s.clone()) {
                        continue;
                    }
                    if let Some(meta) = dict.char_meta(ch) {
                        let short_s = meta.shortest_code.as_string();
                        let full_s = meta.full_code.as_string();
                        let code_desc = if !short_s.is_empty() && short_s != full_s {
                            if py_disp.is_empty() {
                                format!("{} · {}", short_s, full_s)
                            } else {
                                format!("{} · {} ({})", short_s, full_s, py_disp)
                            }
                        } else if py_disp.is_empty() {
                            full_s
                        } else {
                            format!("{} ({})", full_s, py_disp)
                        };
                        self.candidates.push(Candidate {
                            text: s,
                            matched_code: meta.full_code,
                            comment: code_desc,
                            badge: CandidateBadge::PinyinLookup,
                            confidence: 1.0,
                            is_exact: true,
                        });
                    }
                }
            }
        }
    }

    fn build_wildcard_candidates(&mut self, slot: usize) {
        let dict = self.dicts[slot].as_ref().unwrap();
        let codes = expand_wildcards(self.raw_code.as_bytes());
        let mut raw_hits = Vec::<(String, PackedCode, u32)>::new();
        for c in codes {
            for (utext, ucnt, _) in self.user.lookup_exact(c) {
                raw_hits.push((utext.to_string(), c, 900_000_000 + ucnt * 10_000));
            }
            for e in dict.lookup_exact(c, self.config.enable_rare_charset) {
                raw_hits.push((e.text.to_string(), c, e.weight));
            }
        }
        raw_hits.sort_by(|a, b| b.2.cmp(&a.2));
        let mut seen = HashSet::<String>::new();
        for (text, code, _) in raw_hits.into_iter().take(60) {
            if seen.insert(text.clone()) {
                self.candidates.push(Candidate {
                    text,
                    matched_code: code,
                    comment: code.as_string(),
                    badge: CandidateBadge::Wildcard,
                    confidence: 1.0,
                    is_exact: true,
                });
            }
        }
    }

    fn build_standard_and_typo_candidates(&mut self, slot: usize) {
        let dict = self.dicts[slot].as_ref().unwrap();
        let Some(exact_code) = PackedCode::from_ascii(&self.raw_code) else {
            return;
        };
        let lm_w = self.lm_weights;
        let neural_view = if lm_w.neural_scale > 0.0 && self.neural_tracker.is_ready() {
            self.aux.as_ref().and_then(|a| a.neural_view())
        } else {
            None
        };

        // 1. Collect Exact Candidates (preserving canonical Wubi ordering!)
        struct ExactItem {
            text: String,
            code: PackedCode,
            comment: String,
            badge: CandidateBadge,
            sort_bucket: u8, // 0 = exact primary, 1 = dynamic/dict exact, 2 = demoted strict_shortcode, 3 = prefix completion
            order_score: f64,
            base_score: f32,
            posterior_score: f32,
        }

        let mut exact_items = Vec::<ExactItem>::new();
        let mut exact_seen = HashSet::<String>::new();

        // 1a. User phrases at exact_code
        let user_hits = self.user.lookup_exact(exact_code);
        for (idx, (utext, ucnt, _)) in user_hits.into_iter().enumerate() {
            if !exact_seen.insert(utext.to_string()) {
                continue;
            }
            let ctx = compute_context_boost(
                &self.user,
                self.aux.as_ref(),
                &self.last_committed,
                &self.recent_context,
                utext,
                &lm_w,
            );
            let n_fast = neural_view
                .as_ref()
                .map(|nv| lm_w.neural_scale * smooth_neural_score(nv.score_phrase_fast(&self.neural_tracker.active, utext)))
                .unwrap_or(0.0);
            let base = 8.8 + ((ucnt as f32 + 1.0).ln() * 0.8) + ctx;
            let post = base + n_fast;
            let ord = if self.config.dynamic_word_freq {
                1_000_000.0 + (ucnt as f64) * 100.0 + ((ctx + n_fast) as f64) * 500.0 - (idx as f64)
            } else {
                500_000.0 - (idx as f64)
            };
            exact_items.push(ExactItem {
                text: utext.to_string(),
                code: exact_code,
                comment: String::new(),
                badge: CandidateBadge::UserPhrase,
                sort_bucket: 1,
                order_score: ord,
                base_score: base,
                posterior_score: post,
            });
        }

        // 1b. Built-in dictionary exact matches
        let dict_exact = dict.lookup_exact(exact_code, self.config.enable_rare_charset);
        for (rank, entry) in dict_exact.iter().enumerate() {
            if !exact_seen.insert(entry.text.to_string()) {
                continue;
            }
            let mut badge = CandidateBadge::None;
            let mut comment = String::new();
            let mut demoted = false;

            if entry.is_single_char() {
                if let Some(ch) = entry.text.chars().next() {
                    if let Some(meta) = dict.char_meta(ch) {
                        // Short-code hint when user typed longer code than shortest_code
                        if self.config.show_shortcode_hint
                            && !meta.shortest_code.is_empty()
                            && meta.shortest_code.len() < exact_code.len()
                        {
                            badge = CandidateBadge::Shortcode;
                            comment = format!("⚡{}", meta.shortest_code.as_string());
                        }
                        // Strict shortcode ("出简不出全"): demote at 4-code if char has a primary short code
                        if self.config.strict_shortcode
                            && exact_code.len() == 4
                            && !meta.primary_short_code.is_empty()
                            && meta.primary_short_code.len() < 4
                        {
                            demoted = true;
                        }
                    }
                }
            }

            let ctx = compute_context_boost(
                &self.user,
                self.aux.as_ref(),
                &self.last_committed,
                &self.recent_context,
                entry.text,
                &lm_w,
            );
            let prior = compute_candidate_prior(
                self.aux.as_ref(),
                entry.weight,
                entry.text,
                entry.is_single_char(),
                exact_code.len(),
                &lm_w,
            );
            let n_fast = neural_view
                .as_ref()
                .map(|nv| lm_w.neural_scale * smooth_neural_score(nv.score_phrase_fast(&self.neural_tracker.active, entry.text)))
                .unwrap_or(0.0);
            let base = prior + ctx;
            let post = base + n_fast;

            // Preserve #1 fixed muscle-memory slot unless dynamic freq is explicitly enabled for this kind!
            let allow_dyn = if entry.is_single_char() {
                self.config.dynamic_char_freq
            } else {
                self.config.dynamic_word_freq
            };

            let (bucket, ord) = if demoted {
                (2u8, 10_000.0 - rank as f64)
            } else if rank == 0 && !allow_dyn {
                // Sacred #1 slot for fixed-order single-char muscle memory!
                (0u8, 10_000_000.0)
            } else if allow_dyn {
                let dyn_bonus = ((ctx + n_fast * 0.5) as f64) * 1800.0
                    + (self.user.unigram_boost(entry.text) as f64) * 1200.0;
                let base_rank_score = 900_000.0 - (rank as f64) * 1500.0;
                (1u8, base_rank_score + dyn_bonus)
            } else {
                (1u8, 900_000.0 - (rank as f64) * 1500.0)
            };

            exact_items.push(ExactItem {
                text: entry.text.to_string(),
                code: exact_code,
                comment,
                badge,
                sort_bucket: bucket,
                order_score: ord,
                base_score: base,
                posterior_score: post,
            });
        }

        // 1c. Prefix completions when `raw_code.len() < 4` (placed AFTER exact shortcodes when `shortest_code_first` is true!)
        if exact_code.len() < 4 && exact_items.len() < 15 {
            let need = 15 - exact_items.len();
            for (pcode, utext, ucnt) in self.user.lookup_prefix(exact_code, 4) {
                if exact_seen.insert(utext.to_string()) {
                    let tail = &pcode.as_string()[exact_code.len()..];
                    exact_items.push(ExactItem {
                        text: utext.to_string(),
                        code: pcode,
                        comment: format!("…{}", tail),
                        badge: CandidateBadge::UserPhrase,
                        sort_bucket: if self.config.shortest_code_first { 3 } else { 1 },
                        order_score: 50_000.0 + ucnt as f64,
                        base_score: 7.5,
                        posterior_score: 7.5,
                    });
                }
            }
            for e in dict.lookup_longer_prefix(exact_code, need, false) {
                if exact_seen.insert(e.text.to_string()) {
                    let full_str = e.code.as_string();
                    let tail = if full_str.len() > exact_code.len() {
                        &full_str[exact_code.len()..]
                    } else {
                        ""
                    };
                    let bucket = if self.config.shortest_code_first { 3 } else { 1 };
                    let bs = 0.45 * ((e.weight as f32) + 50.0).ln();
                    exact_items.push(ExactItem {
                        text: e.text.to_string(),
                        code: e.code,
                        comment: if tail.is_empty() {
                            String::new()
                        } else {
                            format!("…{}", tail)
                        },
                        badge: CandidateBadge::None,
                        sort_bucket: bucket,
                        order_score: (e.weight as f64) * 0.0001,
                        base_score: bs,
                        posterior_score: bs,
                    });
                }
            }
        }

        exact_items.sort_by(|a, b| {
            a.sort_bucket
                .cmp(&b.sort_bucket)
                .then_with(|| {
                    b.order_score
                        .partial_cmp(&a.order_score)
                        .unwrap_or(core::cmp::Ordering::Equal)
                })
        });

        // 2. Statistical + Touch-Region + Neural RWKV-7 Typo-Correction Decoder (for 2..=4 key codes)
        struct FuzzyItem {
            text: String,
            code: PackedCode,
            base_score: f32,
            posterior_score: f32,
            boundary_slip: bool,
            kind: CorrectionKind,
        }

        let mut fuzzy_items = Vec::<FuzzyItem>::new();
        if self.config.typo.enabled && self.observations.len() >= 2 {
            let hyps = generate_hypotheses(
                &self.observations,
                &self.key_layout,
                &self.user.touch_profile,
                &self.config.typo,
            );

            let mut fuzzy_seen = HashSet::<String>::new();
            for item in &exact_items {
                if item.sort_bucket <= 2 {
                    fuzzy_seen.insert(item.text.clone());
                }
            }

            let spatial_scale = if self
                .aux
                .as_ref()
                .map(|a| a.has_unigrams())
                .unwrap_or(false)
            {
                lm_w.spatial_scale
            } else {
                2.05
            };

            for h in hyps {
                if h.kind == CorrectionKind::Exact || h.code == exact_code {
                    continue;
                }
                // Check user phrases on neighbor hypothesis
                for (utext, ucnt, _) in self.user.lookup_exact(h.code).into_iter().take(2) {
                    if !fuzzy_seen.insert(utext.to_string()) {
                        continue;
                    }
                    let ctx = compute_context_boost(
                        &self.user,
                        self.aux.as_ref(),
                        &self.last_committed,
                        &self.recent_context,
                        utext,
                        &lm_w,
                    );
                    let n_fast = neural_view
                        .as_ref()
                        .map(|nv| lm_w.neural_scale * smooth_neural_score(nv.score_phrase_fast(&self.neural_tracker.active, utext)))
                        .unwrap_or(0.0);
                    let prior = 9.0 + ((ucnt as f32 + 1.0).ln() * 0.75);
                    let base = spatial_scale * h.spatial_logp + prior + ctx;
                    fuzzy_items.push(FuzzyItem {
                        text: utext.to_string(),
                        code: h.code,
                        base_score: base,
                        posterior_score: base + n_fast,
                        boundary_slip: h.boundary_slip,
                        kind: h.kind,
                    });
                }
                // Check top dictionary entries on neighbor hypothesis
                for e in dict.lookup_exact(h.code, false).into_iter().take(4) {
                    if !fuzzy_seen.insert(e.text.to_string()) {
                        continue;
                    }
                    if e.weight < 5_000 {
                        let known_modern = self
                            .aux
                            .as_ref()
                            .and_then(|a| e.text.chars().next().and_then(|c| a.unigram_prior(c)))
                            .map(|u| u >= 3.5)
                            .unwrap_or(false);
                        if !known_modern {
                            continue;
                        }
                    }
                    let ctx = compute_context_boost(
                        &self.user,
                        self.aux.as_ref(),
                        &self.last_committed,
                        &self.recent_context,
                        e.text,
                        &lm_w,
                    );
                    let prior = compute_candidate_prior(
                        self.aux.as_ref(),
                        e.weight,
                        e.text,
                        e.is_single_char(),
                        h.code.len(),
                        &lm_w,
                    );
                    let n_fast = neural_view
                        .as_ref()
                        .map(|nv| lm_w.neural_scale * smooth_neural_score(nv.score_phrase_fast(&self.neural_tracker.active, e.text)))
                        .unwrap_or(0.0);
                    let base = spatial_scale * h.spatial_logp + prior + ctx;
                    fuzzy_items.push(FuzzyItem {
                        text: e.text.to_string(),
                        code: h.code,
                        base_score: base,
                        posterior_score: base + n_fast,
                        boundary_slip: h.boundary_slip,
                        kind: h.kind,
                    });
                }
            }

            fuzzy_items.sort_by(|a, b| {
                b.posterior_score
                    .partial_cmp(&a.posterior_score)
                    .unwrap_or(core::cmp::Ordering::Equal)
            });

            // Stage 2b: Exact multi-token RWKV-7 recurrent unroll only when fuzzy candidates are
            // competitive with exact (or exact is empty), keeping ordinary keystrokes < 15 µs!
            if let Some(ref nv) = neural_view {
                if !fuzzy_items.is_empty() {
                    let best_exact_fast = exact_items
                        .iter()
                        .filter(|x| x.sort_bucket <= 2)
                        .map(|x| x.posterior_score)
                        .fold(f32::NEG_INFINITY, f32::max);
                    let best_fuzzy_fast = fuzzy_items[0].posterior_score;
                    let needs_exact_unroll = !best_exact_fast.is_finite()
                        || (best_fuzzy_fast >= best_exact_fast - 5.0);
                    if needs_exact_unroll {
                        for item in exact_items.iter_mut().filter(|x| x.sort_bucket <= 2).take(2) {
                            if item.text.chars().nth(1).is_some() {
                                let n_ex = lm_w.neural_scale
                                    * smooth_neural_score(nv.score_phrase_exact(&self.neural_tracker.active, &item.text));
                                item.posterior_score = item.base_score + n_ex;
                            }
                        }
                        let refine_k = fuzzy_items.len().min(4);
                        for f in &mut fuzzy_items[..refine_k] {
                            if f.text.chars().nth(1).is_some() {
                                let n_ex = lm_w.neural_scale
                                    * smooth_neural_score(nv.score_phrase_exact(&self.neural_tracker.active, &f.text));
                                f.posterior_score = f.base_score + n_ex;
                            }
                        }
                        fuzzy_items[..refine_k].sort_by(|a, b| {
                            b.posterior_score
                                .partial_cmp(&a.posterior_score)
                                .unwrap_or(core::cmp::Ordering::Equal)
                        });
                    }
                }
            }

            fuzzy_items.truncate(4);
        }

        // 3. Compute calibrated Softmax confidences over top exact (bucket <= 2) + top fuzzy hypotheses!
        let has_direct_exact = exact_items.iter().any(|x| x.sort_bucket <= 2);
        let best_exact_post = exact_items
            .iter()
            .filter(|x| x.sort_bucket <= 2)
            .map(|x| x.posterior_score)
            .fold(f32::NEG_INFINITY, f32::max);

        let mut pool_scores = Vec::<f32>::new();
        if has_direct_exact {
            pool_scores.push(best_exact_post);
        }
        for f in &fuzzy_items {
            pool_scores.push(f.posterior_score);
        }
        let probs = softmax_confidences(&pool_scores);
        let exact_conf = if has_direct_exact {
            probs.first().copied().unwrap_or(1.0)
        } else {
            0.0
        };
        let fuzzy_offset = usize::from(has_direct_exact);

        // Convert exact items into final `Candidate`s
        let mut final_exact: Vec<Candidate> = exact_items
            .into_iter()
            .map(|it| Candidate {
                text: it.text,
                matched_code: it.code,
                comment: it.comment,
                badge: it.badge,
                confidence: if it.sort_bucket <= 2 {
                    exact_conf
                } else {
                    exact_conf * 0.5
                },
                is_exact: true,
            })
            .collect();

        // Filter & format qualifying fuzzy corrections
        let mut promoted_fuzzy = Vec::<Candidate>::new();
        let mut secondary_fuzzy = Vec::<Candidate>::new();

        for (i, f) in fuzzy_items.into_iter().enumerate() {
            let conf = probs.get(fuzzy_offset + i).copied().unwrap_or(0.0);
            let tag_prefix = match f.kind {
                CorrectionKind::Transposition => "⇄",
                CorrectionKind::TouchBoundary => "⌖",
                _ => "⟲",
            };
            let cand = Candidate {
                text: f.text,
                matched_code: f.code,
                comment: format!("{}{} {:.0}%", tag_prefix, f.code.as_string(), conf * 100.0),
                badge: CandidateBadge::TypoCorrected,
                confidence: conf,
                is_exact: false,
            };

            // When should a typo-corrected candidate promote to #1?
            // 1) Direct exact code is EMPTY (空码救回) and confidence >= promote_threshold (or >= 0.65 when no other options)
            // 2) Touch landed on key boundary (`f.boundary_slip`) AND posterior confidence >= promote_threshold
            let rescue_empty = !has_direct_exact && conf >= (self.config.typo.promote_threshold * 0.78);
            let snap_boundary = f.boundary_slip && conf >= self.config.typo.promote_threshold;

            if promoted_fuzzy.is_empty() && (rescue_empty || snap_boundary) {
                promoted_fuzzy.push(cand);
            } else if conf >= self.config.typo.suggest_threshold
                || (!has_direct_exact && secondary_fuzzy.len() < 2 && conf >= 0.20)
            {
                secondary_fuzzy.push(cand);
            }
        }

        // Assemble final candidate list:
        // - Any promoted rescue/boundary-snap #1 goes first
        // - Exact primary candidate(s) stay right at the top
        // - Secondary fuzzy suggestions slot cleanly at position 1..=2 (right after #1 exact) so 1-key press '2' selects them!
        self.candidates.extend(promoted_fuzzy);
        if !final_exact.is_empty() {
            let first_exact = final_exact.remove(0);
            self.candidates.push(first_exact);
            for sf in secondary_fuzzy.drain(..) {
                self.candidates.push(sf);
            }
            self.candidates.extend(final_exact);
        } else {
            self.candidates.extend(secondary_fuzzy);
        }
    }
}

#[inline]
fn smooth_neural_score(raw_lp: f32) -> f32 {
    // Soft floor (-13.5 nats ~ 1.4e-6) guards against extreme OOV outliers while keeping full
    // negative penalty against nonsensical colliding typos (-10..-13.5 nats).
    raw_lp.clamp(-13.5, -0.02) + 11.0
}

#[inline]
fn is_cjk_char(ch: char) -> bool {
    let u = ch as u32;
    (0x4E00..=0x9FFF).contains(&u) || (0x3400..=0x4DBF).contains(&u)
}

#[inline]
fn is_standalone_common_char(ch: char) -> bool {
    matches!(
        ch,
        '的' | '了' | '是' | '在' | '我' | '你' | '他' | '她' | '它' | '们'
            | '也' | '都' | '就' | '还' | '很' | '太' | '不' | '没' | '有' | '要'
            | '会' | '能' | '想' | '看' | '说' | '去' | '来' | '给' | '把' | '被'
            | '和' | '跟' | '与' | '吗' | '呢' | '吧' | '啊' | '呀' | '嘛' | '哦'
            | '这' | '那' | '个' | '一' | '上' | '下' | '里' | '中' | '人' | '大' | '小'
    )
}

#[inline]
fn is_numeral_char(ch: char) -> bool {
    matches!(ch, '零' | '一' | '二' | '三' | '四' | '五' | '六' | '七' | '八' | '九' | '十' | '百' | '千' | '万' | '两')
}

#[inline]
fn is_numeral_pair(c1: char, c2: char) -> bool {
    is_numeral_char(c1) && is_numeral_char(c2) && !(c1 == '一' && c2 == '个')
}

#[inline]
fn compute_candidate_prior(
    aux: Option<&AuxView>,
    dict_weight: u32,
    cand_text: &str,
    is_single_char: bool,
    code_len: usize,
    w: &LmWeights,
) -> f32 {
    let phrase_bonus = if !is_single_char && code_len == 4 {
        w.phrase_bonus
    } else {
        0.0
    };
    let Some(aux_v) = aux.filter(|a| a.has_unigrams()) else {
        // Legacy WBAUX001 fallback (no corpus unigram section)
        return 0.52 * ((dict_weight as f32) + 50.0).ln() + phrase_bonus;
    };

    let dict_prior = w.dict_prior_scale * ((dict_weight as f32) + 50.0).ln();
    let mut chars_buf = ['\0'; 8];
    let mut n = 0usize;
    for ch in cand_text.chars().take(8) {
        chars_buf[n] = ch;
        n += 1;
    }
    if n == 0 {
        return dict_prior + phrase_bonus;
    }

    let mut uni_sum = 0.0f32;
    for &ch in &chars_buf[..n] {
        uni_sum += aux_v.unigram_prior(ch).unwrap_or(0.5);
    }
    let mean_uni = uni_sum / (n as f32);

    let mut internal_cohesion = 0.0f32;
    if n >= 2 {
        let mut bg_sum = 0.0f32;
        for i in 0..(n - 1) {
            bg_sum += aux_v.bigram_boost(chars_buf[i], chars_buf[i + 1]);
        }
        internal_cohesion = (bg_sum / ((n - 1) as f32)).min(4.5);
    }

    dict_prior
        + w.corpus_unigram_scale * mean_uni
        + w.internal_bigram_scale * internal_cohesion
        + phrase_bonus
}

#[inline]
fn compute_context_boost(
    user: &UserStore,
    aux: Option<&AuxView>,
    last_committed: &str,
    recent_context: &[char],
    cand_text: &str,
    w: &LmWeights,
) -> f32 {
    let mut boost = user.context_boost(last_committed, cand_text);
    let Some(aux_v) = aux else {
        return boost;
    };
    let Some(p1) = recent_context.last().copied() else {
        return boost;
    };
    let mut cand_chars = cand_text.chars();
    let Some(c0) = cand_chars.next() else {
        return boost;
    };

    let bg = aux_v.bigram_boost(p1, c0);
    if !aux_v.has_unigrams() {
        // Legacy WBAUX001 scale
        boost += 1.35 * bg;
        return boost;
    }

    let prev2 = if recent_context.len() >= 2 {
        Some(recent_context[recent_context.len() - 2])
    } else {
        None
    };
    let tg1 = prev2.map(|p2| aux_v.trigram_boost(p2, p1, c0)).unwrap_or(0.0);
    let tg_cross = cand_chars
        .next()
        .map(|c1| aux_v.trigram_boost(p1, c0, c1))
        .unwrap_or(0.0);

    boost += w.bigram_scale * bg + w.trigram_scale * tg1 + w.cross_trigram_scale * tg_cross;
    boost
}
