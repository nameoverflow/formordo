use crate::code::{expand_wildcards, PackedCode};
use crate::config::{FourthEmptyBehavior, ShiftToggleMode, WubiConfig, WubiSchema};
use crate::format::{AuxView, DictView, ENTRY_FLAG_SYMBOL};
use crate::typo::{generate_hypotheses, softmax_confidences, CorrectionKind, KeyLayout, KeyObs};
use crate::user_data::UserStore;
use std::collections::HashSet;

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

pub struct WubiEngine {
    pub dicts: [Option<DictView>; 3],
    pub aux: Option<AuxView>,
    pub config: WubiConfig,
    pub user: UserStore,
    pub key_layout: KeyLayout,

    pub ascii_mode: bool,
    raw_code: String,
    observations: Vec<KeyObs>,
    candidates: Vec<Candidate>,
    page: usize,
    last_committed: String,
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
            ascii_mode: false,
            raw_code: String::new(),
            observations: Vec::new(),
            candidates: Vec::new(),
            page: 0,
            last_committed: String::new(),
            double_quote_open: false,
            single_quote_open: false,
        }
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
        }
        self.ascii_mode = !self.ascii_mode;
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
            // rectangular keycaps, ergonomic thumb Y-bias, and `valid_next_mask` — and showed
            // the callout bubble for `reported_lower`. Keep `reported_lower` whenever `(nx, ny)`
            // lies within its keycap/expanded neighborhood so staggered neighbor rows (`e` vs `d`)
            // never silently hijack a corner tap away from what the callout displayed.
            let (cx, cy) = self.key_layout.center_of(reported_lower);
            let d2 = (nx - cx).powi(2) + (ny - cy).powi(2);
            if d2 <= 0.68 * 0.68 {
                reported_lower
            } else if self.config.typo.enabled && self.config.typo.touch_hitbox_adapt {
                self.key_layout
                    .nearest_key(nx, ny, &self.user.touch_profile, true)
            } else {
                reported_lower
            }
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
                    return EngineOutput::default();
                }
                let raw = self.raw_code.clone();
                self.clear_composition();
                self.user.break_single_burst();
                return EngineOutput {
                    consumed: true,
                    commit_text: raw,
                    ..Default::default()
                };
            }
            KEY_SPACE => {
                if self.raw_code.is_empty() {
                    self.user.break_single_burst();
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
        let prev_last_char = self.last_committed.chars().last();

        // 1. Collect Exact Candidates (preserving canonical Wubi ordering!)
        struct ExactItem {
            text: String,
            code: PackedCode,
            comment: String,
            badge: CandidateBadge,
            sort_bucket: u8, // 0 = exact primary, 1 = dynamic/dict exact, 2 = demoted strict_shortcode, 3 = prefix completion
            order_score: f64,
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
            let ctx = compute_context_boost(&self.user, self.aux.as_ref(), &self.last_committed, prev_last_char, utext);
            let post = 8.8 + ((ucnt as f32 + 1.0).ln() * 0.8) + ctx;
            let ord = if self.config.dynamic_word_freq {
                1_000_000.0 + (ucnt as f64) * 100.0 + (ctx as f64) * 500.0 - (idx as f64)
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

            let ctx = compute_context_boost(&self.user, self.aux.as_ref(), &self.last_committed, prev_last_char, entry.text);
            let prior = 0.52 * ((entry.weight as f32) + 50.0).ln();
            let post = prior + ctx;

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
                let dyn_bonus = (ctx as f64) * 1800.0 + (self.user.unigram_boost(entry.text) as f64) * 1200.0;
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
                        posterior_score: 0.45 * ((e.weight as f32) + 50.0).ln(),
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

        // 2. Statistical + Touch-Region Typo-Correction Decoder (for 2..=4 key codes)
        struct FuzzyItem {
            text: String,
            code: PackedCode,
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

            for h in hyps {
                if h.kind == CorrectionKind::Exact || h.code == exact_code {
                    continue;
                }
                // Check user phrases on neighbor hypothesis
                for (utext, ucnt, _) in self.user.lookup_exact(h.code).into_iter().take(2) {
                    if !fuzzy_seen.insert(utext.to_string()) {
                        continue;
                    }
                    let ctx = compute_context_boost(&self.user, self.aux.as_ref(), &self.last_committed, prev_last_char, utext);
                    let prior = 9.0 + ((ucnt as f32 + 1.0).ln() * 0.75);
                    let post = 2.05 * h.spatial_logp + prior + ctx;
                    fuzzy_items.push(FuzzyItem {
                        text: utext.to_string(),
                        code: h.code,
                        posterior_score: post,
                        boundary_slip: h.boundary_slip,
                        kind: h.kind,
                    });
                }
                // Check top dictionary entries on neighbor hypothesis
                for e in dict.lookup_exact(h.code, false).into_iter().take(2) {
                    if !fuzzy_seen.insert(e.text.to_string()) {
                        continue;
                    }
                    // Skip zero-weight ultra-obscure items as typo rescue targets
                    if e.weight < 5_000 {
                        continue;
                    }
                    let ctx = compute_context_boost(&self.user, self.aux.as_ref(), &self.last_committed, prev_last_char, e.text);
                    let prior = 0.52 * ((e.weight as f32) + 50.0).ln();
                    let phrase_bonus = if !e.is_single_char() && h.code.len() == 4 {
                        0.65 // 4-letter phrases have much higher redundancy than random single chars!
                    } else {
                        0.0
                    };
                    let post = 2.05 * h.spatial_logp + prior + ctx + phrase_bonus;
                    fuzzy_items.push(FuzzyItem {
                        text: e.text.to_string(),
                        code: h.code,
                        posterior_score: post,
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
fn compute_context_boost(
    user: &UserStore,
    aux: Option<&AuxView>,
    last_committed: &str,
    prev_last_char: Option<char>,
    cand_text: &str,
) -> f32 {
    let mut boost = user.context_boost(last_committed, cand_text);
    if let (Some(aux_v), Some(p_ch), Some(n_ch)) = (aux, prev_last_char, cand_text.chars().next()) {
        boost += 1.35 * aux_v.bigram_boost(p_ch, n_ch);
    }
    boost
}
