use crate::code::PackedCode;
use crate::format::DictView;
use std::collections::HashMap;
use std::fs;
use std::io;
use std::path::Path;

pub const MAX_TOUCH_OFFSET: f32 = 0.20; // Clamp adaptive hitbox shift to ±0.20 key-pitch

#[derive(Clone, Copy, Debug, Default)]
pub struct TouchKeyOffset {
    pub dx: f32,
    pub dy: f32,
    pub samples: u32,
}

#[derive(Clone, Debug)]
pub struct TouchProfile {
    pub keys: [TouchKeyOffset; 26],
}

impl Default for TouchProfile {
    fn default() -> Self {
        Self {
            keys: [TouchKeyOffset::default(); 26],
        }
    }
}

impl TouchProfile {
    /// Update personal touch center offset for `key` ('a'..='z') from observed residual
    /// `(obs_norm_x - canonical_cx, obs_norm_y - canonical_cy)`.
    pub fn observe(&mut self, key_byte: u8, residual_x: f32, residual_y: f32) {
        if !key_byte.is_ascii_lowercase() {
            return;
        }
        // Ignore wild outliers (> 0.85 key-widths away) so accidental fat-finger taps don't skew calibration
        if residual_x.abs() > 0.85 || residual_y.abs() > 0.85 {
            return;
        }
        let idx = (key_byte - b'a') as usize;
        let entry = &mut self.keys[idx];
        let alpha = if entry.samples < 10 { 0.14 } else { 0.06 };
        entry.dx = ((1.0 - alpha) * entry.dx + alpha * residual_x)
            .clamp(-MAX_TOUCH_OFFSET, MAX_TOUCH_OFFSET);
        entry.dy = ((1.0 - alpha) * entry.dy + alpha * residual_y)
            .clamp(-MAX_TOUCH_OFFSET, MAX_TOUCH_OFFSET);
        entry.samples = entry.samples.saturating_add(1);
    }

    pub fn reset(&mut self) {
        self.keys = [TouchKeyOffset::default(); 26];
    }

    #[inline]
    pub fn offset_for(&self, key_byte: u8) -> (f32, f32) {
        if key_byte.is_ascii_lowercase() {
            let e = self.keys[(key_byte - b'a') as usize];
            (e.dx, e.dy)
        } else {
            (0.0, 0.0)
        }
    }
}

#[derive(Clone, Debug)]
pub struct UserPhrase {
    pub text: String,
    pub count: u32,
    pub last_seq: u64,
    pub auto_composed: bool,
}

pub struct UserStore {
    pub seq: u64,
    pub phrases: HashMap<String, UserPhrase>,
    /// Active schema code -> list of `(text, count, last_seq)`
    code_index: HashMap<PackedCode, Vec<String>>,
    pub unigram_counts: HashMap<String, u32>,
    pub word_bigrams: HashMap<(String, String), u32>,
    pub char_bigrams: HashMap<(char, char), u32>,
    pub touch_profile: TouchProfile,
    /// Rolling buffer of recent consecutive single-char commits `(ch, timestamp_ms)`
    recent_singles: Vec<(char, u64)>,
    /// Candidate consecutive n-grams waiting to reach `auto_phrase_threshold`
    pending_ngrams: HashMap<String, u8>,
    pub dirty: bool,
}

impl Default for UserStore {
    fn default() -> Self {
        Self {
            seq: 1,
            phrases: HashMap::new(),
            code_index: HashMap::new(),
            unigram_counts: HashMap::new(),
            word_bigrams: HashMap::new(),
            char_bigrams: HashMap::new(),
            touch_profile: TouchProfile::default(),
            recent_singles: Vec::new(),
            pending_ngrams: HashMap::new(),
            dirty: false,
        }
    }
}

impl UserStore {
    /// Rebuild active Wubi phrase codes for all user phrases using `dict`'s character stems.
    /// This makes user phrases & auto-composed phrases work seamlessly across 86 / 98 / 新世纪!
    pub fn reindex_phrases(&mut self, dict: &DictView) {
        self.code_index.clear();
        for text in self.phrases.keys() {
            if let Some(code) = dict.encode_phrase(text) {
                self.code_index.entry(code).or_default().push(text.clone());
            }
        }
        for bucket in self.code_index.values_mut() {
            bucket.sort_by(|a, b| {
                let pa = &self.phrases[a];
                let pb = &self.phrases[b];
                pb.count
                    .cmp(&pa.count)
                    .then_with(|| pb.last_seq.cmp(&pa.last_seq))
            });
        }
    }

    pub fn lookup_exact(&self, code: PackedCode) -> Vec<(&str, u32, u64)> {
        let Some(list) = self.code_index.get(&code) else {
            return Vec::new();
        };
        list.iter()
            .filter_map(|t| {
                let p = self.phrases.get(t)?;
                Some((p.text.as_str(), p.count, p.last_seq))
            })
            .collect()
    }

    pub fn lookup_prefix(&self, prefix: PackedCode, limit: usize) -> Vec<(PackedCode, &str, u32)> {
        let (lo, hi) = prefix.prefix_range();
        let mut out = Vec::new();
        for (&code, texts) in &self.code_index {
            if code > lo && code <= hi {
                for t in texts {
                    if let Some(p) = self.phrases.get(t) {
                        out.push((code, p.text.as_str(), p.count));
                    }
                }
            }
        }
        out.sort_by(|a, b| a.0.len().cmp(&b.0.len()).then_with(|| b.2.cmp(&a.2)));
        out.truncate(limit);
        out
    }

    pub fn add_phrase(
        &mut self,
        text: &str,
        auto_composed: bool,
        dict: Option<&DictView>,
    ) -> Option<PackedCode> {
        let char_len = text.chars().count();
        if char_len < 2 || char_len > 12 {
            return None;
        }
        self.seq += 1;
        let seq = self.seq;
        let entry = self
            .phrases
            .entry(text.to_string())
            .and_modify(|e| {
                e.count = e.count.saturating_add(1);
                e.last_seq = seq;
            })
            .or_insert_with(|| UserPhrase {
                text: text.to_string(),
                count: 1,
                last_seq: seq,
                auto_composed,
            });
        let _ = entry;
        self.dirty = true;
        if let Some(d) = dict {
            if let Some(code) = d.encode_phrase(text) {
                let list = self.code_index.entry(code).or_default();
                if !list.iter().any(|s| s == text) {
                    list.push(text.to_string());
                }
                return Some(code);
            }
        }
        None
    }

    pub fn remove_phrase(&mut self, text: &str) -> bool {
        let existed = self.phrases.remove(text).is_some();
        if existed {
            for list in self.code_index.values_mut() {
                list.retain(|s| s != text);
            }
            self.dirty = true;
        }
        existed
    }

    pub fn break_single_burst(&mut self) {
        self.recent_singles.clear();
    }

    /// Record a committed string, updating personal unigram/bigram frequencies and
    /// optionally triggering automatic consecutive single-character phrase formation.
    /// Returns `Some(newly_learned_phrase)` when auto-phrase promotes a new word!
    pub fn record_commit(
        &mut self,
        prev_committed: &str,
        committed: &str,
        timestamp_ms: u64,
        auto_phrase: bool,
        auto_threshold: u8,
        dict: Option<&DictView>,
    ) -> Option<String> {
        if committed.is_empty() {
            return None;
        }
        self.seq += 1;
        let seq = self.seq;
        self.dirty = true;

        *self
            .unigram_counts
            .entry(committed.to_string())
            .or_insert(0) += 1;

        if let Some(up) = self.phrases.get_mut(committed) {
            up.count = up.count.saturating_add(1);
            up.last_seq = seq;
        }

        if !prev_committed.is_empty() {
            if self.word_bigrams.len() < 8192 {
                *self
                    .word_bigrams
                    .entry((prev_committed.to_string(), committed.to_string()))
                    .or_insert(0) += 1;
            }
            if let (Some(c_prev), Some(c_next)) =
                (prev_committed.chars().last(), committed.chars().next())
            {
                if self.char_bigrams.len() < 8192 {
                    *self.char_bigrams.entry((c_prev, c_next)).or_insert(0) += 1;
                }
            }
        }

        // Consecutive single-character burst tracking for auto-phrase!
        let mut chars = committed.chars();
        let first_ch = chars.next()?;
        let is_single_cjk = chars.next().is_none() && is_cjk_ideograph(first_ch);

        if !is_single_cjk {
            self.recent_singles.clear();
            return None;
        }

        if let Some(&(_, last_ts)) = self.recent_singles.last() {
            if timestamp_ms > 0 && last_ts > 0 && timestamp_ms.saturating_sub(last_ts) > 5000 {
                self.recent_singles.clear();
            }
        }
        self.recent_singles.push((first_ch, timestamp_ms));
        if self.recent_singles.len() > 4 {
            self.recent_singles.remove(0);
        }

        if !auto_phrase || self.recent_singles.len() < 2 {
            return None;
        }

        // Check 2-char suffix (and 3-char suffix if available)
        let n = self.recent_singles.len();
        let cand2: String = self.recent_singles[n - 2..n].iter().map(|x| x.0).collect();
        let promoted = self.bump_pending_ngram(&cand2, auto_threshold, dict);
        if promoted.is_some() {
            return promoted;
        }
        if n >= 3 {
            let cand3: String = self.recent_singles[n - 3..n].iter().map(|x| x.0).collect();
            return self.bump_pending_ngram(&cand3, auto_threshold, dict);
        }
        None
    }

    fn bump_pending_ngram(
        &mut self,
        phrase: &str,
        threshold: u8,
        dict: Option<&DictView>,
    ) -> Option<String> {
        if self.phrases.contains_key(phrase) {
            return None;
        }
        // Skip common functional stop-chars at boundaries (的、了、是、在、我、你、他、吗、呢、吧、啊)
        // so typing "我的" or "是在" doesn't pollute user phrases unless already in base dict.
        if phrase.chars().any(is_stop_glue_char) {
            return None;
        }
        if let Some(d) = dict {
            let Some(code) = d.encode_phrase(phrase) else {
                return None;
            };
            // Already exists in built-in dictionary? No need to duplicate
            if d.lookup_exact(code, false)
                .iter()
                .any(|e| e.text == phrase)
            {
                return None;
            }
        }
        let cnt = self.pending_ngrams.entry(phrase.to_string()).or_insert(0);
        *cnt = cnt.saturating_add(1);
        if *cnt >= threshold.max(1) {
            self.pending_ngrams.remove(phrase);
            self.add_phrase(phrase, true, dict);
            return Some(phrase.to_string());
        }
        None
    }

    #[inline]
    pub fn unigram_boost(&self, text: &str) -> f32 {
        let c = self.unigram_counts.get(text).copied().unwrap_or(0);
        if c == 0 {
            0.0
        } else {
            ((c as f32) + 1.0).ln() * 0.65
        }
    }

    /// Personal language model log-boost given `prev_committed` context (in nats).
    #[inline]
    pub fn context_boost(&self, prev_committed: &str, candidate: &str) -> f32 {
        let mut boost = self.unigram_boost(candidate) * 0.5;
        if !prev_committed.is_empty() && !candidate.is_empty() {
            if let Some(&wc) = self
                .word_bigrams
                .get(&(prev_committed.to_string(), candidate.to_string()))
            {
                boost += ((wc as f32) + 1.0).ln() * 1.45;
            }
            if let (Some(cp), Some(cn)) =
                (prev_committed.chars().last(), candidate.chars().next())
            {
                if let Some(&cc) = self.char_bigrams.get(&(cp, cn)) {
                    boost += ((cc as f32) + 1.0).ln() * 0.85;
                }
            }
        }
        boost.min(4.5)
    }

    pub fn save_file<P: AsRef<Path>>(&self, path: P) -> io::Result<()> {
        if let Some(parent) = path.as_ref().parent() {
            fs::create_dir_all(parent)?;
        }
        let mut out = String::from("# PrisWubi User Data v1\n");
        out.push_str(&format!("SEQ\t{}\n", self.seq));
        for (i, t) in self.touch_profile.keys.iter().enumerate() {
            if t.samples > 0 {
                let ch = (b'a' + i as u8) as char;
                out.push_str(&format!(
                    "TOUCH\t{}\t{:.5}\t{:.5}\t{}\n",
                    ch, t.dx, t.dy, t.samples
                ));
            }
        }
        let mut phrases: Vec<&UserPhrase> = self.phrases.values().collect();
        phrases.sort_by(|a, b| b.count.cmp(&a.count));
        for p in phrases.into_iter().take(5000) {
            out.push_str(&format!(
                "PHRASE\t{}\t{}\t{}\t{}\n",
                escape_tab(&p.text),
                p.count,
                p.last_seq,
                if p.auto_composed { 1 } else { 0 }
            ));
        }
        let mut unis: Vec<(&String, &u32)> = self.unigram_counts.iter().collect();
        unis.sort_by(|a, b| b.1.cmp(a.1));
        for (w, c) in unis.into_iter().take(4000) {
            out.push_str(&format!("UNI\t{}\t{}\n", escape_tab(w), c));
        }
        let mut bgs: Vec<(&(String, String), &u32)> = self.word_bigrams.iter().collect();
        bgs.sort_by(|a, b| b.1.cmp(a.1));
        for ((p, n), c) in bgs.into_iter().take(4000) {
            out.push_str(&format!(
                "WBG\t{}\t{}\t{}\n",
                escape_tab(p),
                escape_tab(n),
                c
            ));
        }
        fs::write(path, out)
    }

    pub fn load_file<P: AsRef<Path>>(path: P) -> io::Result<Self> {
        let src = fs::read_to_string(path)?;
        let mut store = Self::default();
        for line in src.lines() {
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let parts: Vec<&str> = line.split('\t').collect();
            match parts.first().copied().unwrap_or("") {
                "SEQ" if parts.len() >= 2 => {
                    store.seq = parts[1].parse().unwrap_or(1);
                }
                "TOUCH" if parts.len() >= 5 => {
                    if let Some(ch) = parts[1].bytes().next() {
                        if ch.is_ascii_lowercase() {
                            let idx = (ch - b'a') as usize;
                            let dx: f32 = parts[2].parse().unwrap_or(0.0);
                            let dy: f32 = parts[3].parse().unwrap_or(0.0);
                            let samples: u32 = parts[4].parse().unwrap_or(0);
                            store.touch_profile.keys[idx] = TouchKeyOffset {
                                dx: dx.clamp(-MAX_TOUCH_OFFSET, MAX_TOUCH_OFFSET),
                                dy: dy.clamp(-MAX_TOUCH_OFFSET, MAX_TOUCH_OFFSET),
                                samples,
                            };
                        }
                    }
                }
                "PHRASE" if parts.len() >= 5 => {
                    let text = parts[1].to_string();
                    let count: u32 = parts[2].parse().unwrap_or(1);
                    let last_seq: u64 = parts[3].parse().unwrap_or(1);
                    let auto_composed = parts[4] == "1";
                    store.phrases.insert(
                        text.clone(),
                        UserPhrase {
                            text,
                            count,
                            last_seq,
                            auto_composed,
                        },
                    );
                }
                "UNI" if parts.len() >= 3 => {
                    if let Ok(c) = parts[2].parse::<u32>() {
                        store.unigram_counts.insert(parts[1].to_string(), c);
                    }
                }
                "WBG" if parts.len() >= 4 => {
                    if let Ok(c) = parts[3].parse::<u32>() {
                        let p = parts[1].to_string();
                        let n = parts[2].to_string();
                        if let (Some(cp), Some(cn)) = (p.chars().last(), n.chars().next()) {
                            *store.char_bigrams.entry((cp, cn)).or_insert(0) += c;
                        }
                        store.word_bigrams.insert((p, n), c);
                    }
                }
                _ => {}
            }
        }
        store.dirty = false;
        Ok(store)
    }
}

fn escape_tab(s: &str) -> String {
    s.replace(['\t', '\n', '\r'], " ")
}

#[inline]
fn is_cjk_ideograph(ch: char) -> bool {
    let u = ch as u32;
    (0x4E00..=0x9FFF).contains(&u) || (0x3400..=0x4DBF).contains(&u)
}

#[inline]
fn is_stop_glue_char(ch: char) -> bool {
    matches!(
        ch,
        '的' | '了' | '着' | '过' | '吗' | '呢' | '吧' | '啊' | '呀' | '哦'
    )
}
