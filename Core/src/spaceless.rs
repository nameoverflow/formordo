use crate::code::PackedCode;
use crate::config::WubiConfig;
use crate::format::{AuxView, DictView};
use crate::neural::{NeuralView, RwkvState};
use crate::personalization::Context as PersonalContext;
use crate::typo::{
    generate_hypotheses_with_options, CorrectionKind, KeyLayout, KeyObs,
};
use crate::user_data::UserStore;
use std::collections::VecDeque;

const BEAM_WIDTH: usize = 8;
const MAX_CODE_LEN: usize = 4;
const RETAINED_LAYERS: usize = 8;
const COMMIT_DELAY: usize = 8;
const COMMIT_SCORE_MARGIN: f32 = 5.0;

pub(crate) struct Decoder<'a> {
    pub dict: &'a DictView,
    pub aux: &'a AuxView,
    pub model: NeuralView<'a>,
    pub config: &'a WubiConfig,
    pub user: &'a UserStore,
    pub context: &'a [char],
    pub layout: &'a KeyLayout,
}

#[derive(Clone, Copy)]
struct Boundary {
    keys: usize,
    text_bytes: usize,
    code: PackedCode,
    correction: CorrectionKind,
}

pub(crate) struct Segment {
    pub text: String,
    pub code: PackedCode,
    pub correction: CorrectionKind,
}

pub(crate) struct Path {
    pub text: String,
    pub score: f32,
    boundaries: Vec<Boundary>,
    state: RwkvState,
    personal_context: PersonalContext,
}

impl Path {
    fn boundary_index(&self, boundary: Boundary) -> Option<usize> {
        let i = self
            .boundaries
            .binary_search_by_key(&boundary.keys, |b| b.keys)
            .ok()?;
        (self.boundaries[i].text_bytes == boundary.text_bytes).then_some(i)
    }

    pub fn tail_start(&self) -> usize {
        self.boundaries.iter().rev().nth(1).map_or(0, |b| b.keys)
    }

    pub fn segments(&self, keys: usize) -> Vec<Segment> {
        let mut start = 0;
        self.boundaries
            .iter()
            .take_while(|boundary| boundary.keys <= keys)
            .map(|boundary| {
                let segment = Segment {
                    text: self.text[start..boundary.text_bytes].to_owned(),
                    code: boundary.code,
                    correction: boundary.correction,
                };
                start = boundary.text_bytes;
                segment
            })
            .collect()
    }

    pub fn correction_hint(&self, keys: usize) -> String {
        self.boundaries
            .iter()
            .take_while(|boundary| boundary.keys <= keys)
            .filter(|boundary| boundary.correction != CorrectionKind::Exact)
            .map(|boundary| boundary.code.as_string())
            .collect::<Vec<_>>()
            .join("·")
    }

    fn code_segments<'a>(&self, code: &'a str) -> Vec<&'a str> {
        let mut start = 0;
        let mut groups = Vec::new();
        for boundary in self.boundaries.iter().take_while(|b| b.keys <= code.len()) {
            groups.push(&code[start..boundary.keys]);
            start = boundary.keys;
        }
        if start < code.len() {
            groups.push(&code[start..]);
        }
        groups
    }
}

pub(crate) struct StablePrefix {
    pub keys: usize,
    pub segments: Vec<Segment>,
    pub codes: Vec<String>,
}

#[derive(Default)]
pub(crate) struct Stream {
    layers: VecDeque<Vec<Path>>,
    // Number of keys represented by the oldest retained layer, relative to the pending code.
    first: usize,
}

impl Stream {
    pub fn update(&mut self, observations: &[KeyObs], decoder: &Decoder<'_>, initial: &RwkvState) {
        while !self.layers.is_empty() && self.first + self.layers.len() > observations.len() + 1 {
            self.layers.pop_back();
        }
        if self.layers.is_empty() || (self.first > 0 && self.layers.len() < MAX_CODE_LEN) {
            self.first = 0;
            self.layers.clear();
            self.layers.push_back(vec![Path {
                text: String::new(),
                score: 0.0,
                boundaries: Vec::new(),
                state: initial.clone(),
                personal_context: PersonalContext::with_chars(decoder.context.iter().copied()),
            }]);
        }
        for end in self.first + self.layers.len()..=observations.len() {
            let next = self.extend(decoder, &observations[..end]);
            self.layers.push_back(next);
            if self.layers.len() > RETAINED_LAYERS {
                self.layers.pop_front();
                self.first += 1;
            }
        }
    }

    fn layer(&self, pos: usize) -> &[Path] {
        pos.checked_sub(self.first)
            .and_then(|index| self.layers.get(index))
            .map_or(&[], Vec::as_slice)
    }

    pub fn paths(&self) -> &[Path] {
        self.layers.back().map_or(&[], Vec::as_slice)
    }

    pub fn preview(&self, code: &str) -> String {
        for (index, layer) in self.layers.iter().enumerate().rev() {
            if let Some(best) = layer.first() {
                let mut text = best.text.clone();
                text.push_str(&code[self.first + index..]);
                return text;
            }
        }
        code.to_owned()
    }

    pub fn segmented_code(&self, code: &str) -> String {
        self.layers
            .iter()
            .rev()
            .find_map(|layer| layer.first())
            .map_or_else(
                || code.to_owned(),
                |best| best.code_segments(code).join("·"),
            )
    }

    /// Include hypotheses that end up to three strokes earlier, if their remaining strokes
    /// can still be the beginning of a longer code.
    pub fn take_stable_prefix(
        &mut self,
        code: &str,
        dict: &DictView,
        user: &UserStore,
        config: &WubiConfig,
    ) -> Option<StablePrefix> {
        let limit = code.len().checked_sub(COMMIT_DELAY)?;
        let best = self.paths().first()?;
        let mut cuts: Vec<Boundary> = best
            .boundaries
            .iter()
            .copied()
            .take_while(|b| b.keys <= limit)
            .collect();
        for tail_len in 0..MAX_CODE_LEN {
            if cuts.is_empty() {
                return None;
            }
            let end = code.len() - tail_len;
            // An invalid raw tail can still grow into a corrected code on the next key.
            if tail_len > 0
                && !config.typo.enabled
                && dict.valid_next_letters_mask(&code.as_bytes()[end..], config.enable_rare_charset)
                    == 0
                && user.valid_next_letters_mask(&code.as_bytes()[end..]) == 0
            {
                continue;
            }
            let layer = self.layer(end);
            if let Some(leader) = layer.first() {
                for path in layer
                    .iter()
                    .take_while(|p| p.score >= leader.score - COMMIT_SCORE_MARGIN)
                {
                    // Different word boundaries can still arrive at the same text and code cut.
                    cuts.retain(|cut| {
                        path.text.starts_with(&best.text[..cut.text_bytes])
                            && path.boundary_index(*cut).is_some()
                    });
                }
            }
        }
        let boundary = *cuts.last()?;
        let prefix = best.text[..boundary.text_bytes].to_owned();
        let segments = best.segments(boundary.keys);
        let codes = best
            .code_segments(&code[..boundary.keys])
            .into_iter()
            .map(str::to_owned)
            .collect();
        let score_base = best.score;
        while self.first < boundary.keys {
            self.layers.pop_front();
            self.first += 1;
        }
        self.first -= boundary.keys;
        for layer in &mut self.layers {
            layer.retain_mut(|path| {
                let Some(boundary_index) = path.boundary_index(boundary) else {
                    return false;
                };
                if !path.text.starts_with(&prefix) {
                    return false;
                }
                path.text.drain(..boundary.text_bytes);
                path.boundaries.drain(..=boundary_index);
                for b in &mut path.boundaries {
                    b.keys -= boundary.keys;
                    b.text_bytes -= boundary.text_bytes;
                }
                path.score -= score_base;
                true
            });
        }
        Some(StablePrefix {
            keys: boundary.keys,
            segments,
            codes,
        })
    }

    fn extend(&self, decoder: &Decoder<'_>, observations: &[KeyObs]) -> Vec<Path> {
        struct Step<'a> {
            parent: &'a Path,
            text: &'a str,
            estimate: f32,
            bias: f32,
            code: PackedCode,
            correction: CorrectionKind,
        }

        let mut steps = Vec::new();
        let end = observations.len();
        let personal = &decoder.user.continuations;
        let personalize = decoder.config.dynamic_word_freq && !personal.is_empty();
        let use_personal_states = personalize && personal.matches_model(&decoder.model);
        for len in 1..=end.min(MAX_CODE_LEN) {
            let parents = self.layer(end - len);
            if parents.is_empty() {
                continue;
            }
            let window = &observations[end - len..];
            let hypotheses = generate_hypotheses_with_options(
                window,
                decoder.layout,
                &decoder.user.touch_profile,
                &decoder.config.typo,
                decoder.config.schema.allows_z_code(),
            );
            let exact_logp = hypotheses
                .iter()
                .find(|hypothesis| hypothesis.kind == CorrectionKind::Exact)
                .map_or(0.0, |hypothesis| hypothesis.spatial_logp);
            let entries = hypotheses
                .into_iter()
                .filter(|hypothesis| {
                    // With a one-letter shortcut, require touch evidence before trying another key.
                    len > 1 || hypothesis.kind != CorrectionKind::NeighborKey
                })
                .flat_map(|hypothesis| {
                    let key = hypothesis.code;
                    let correction = hypothesis.kind;
                    let exact = correction == CorrectionKind::Exact;
                    let relative_logp = if correction == CorrectionKind::Transposition {
                        hypothesis.spatial_logp
                    } else {
                        hypothesis.spatial_logp - exact_logp
                    };
                    let cost = match correction {
                        CorrectionKind::Exact => 0.0,
                        CorrectionKind::TouchBoundary if len > 1 => 2.5,
                        _ => 4.5,
                    };
                    let penalty = cost - 1.65 * relative_logp.min(0.0);
                    let hits = decoder
                        .dict
                        .lookup_exact(key, decoder.config.enable_rare_charset);
                    let users = decoder.user.lookup_exact(key);
                    let limit = if exact { [1, 2, 4, 6][len - 1] } else { 2 };
                    hits.into_iter()
                        .enumerate()
                        .take(if exact && personalize { 24 } else { limit })
                        .filter(move |(rank, entry)| {
                            *rank < limit
                                || parents.iter().any(|parent| {
                                    let score = personal.score(parent.personal_context, entry.text);
                                    score >= 0.6
                                        || (use_personal_states
                                            && entry.text.chars().next().is_some_and(|first| {
                                                personal.state_bonus(
                                                    parent.personal_context,
                                                    first,
                                                    &parent.state,
                                                ) + score
                                                    >= 0.6
                                            }))
                                })
                        })
                        .take(limit + 2)
                        .map(|(rank, entry)| (rank, entry.text, entry.weight, false))
                        .chain(
                            users
                                .into_iter()
                                .take(if exact { 4 } else { 2 })
                                .enumerate()
                                .map(|(rank, (text, _, _))| (rank, text, 500, true)),
                        )
                        .map(move |entry| (entry, key, correction, penalty))
                });
            for ((rank, text, weight, custom), code, correction, penalty) in entries {
                let mut chars = text.chars();
                let Some(first) = chars.next() else { continue };
                let second = chars.next();
                let n_chars = 1 + usize::from(second.is_some()) + chars.count();
                let mut bias = n_chars as f32 * 0.3 - 0.2 - penalty;
                if decoder.config.strict_shortcode && n_chars == 1 {
                    if let Some(meta) = decoder.dict.char_meta(first) {
                        let short_len = meta.primary_short_code.len();
                        if short_len > 0 && short_len < len {
                            // Keep longer codes available, but prefer the user's normal short-code path.
                            bias -= 2.5 + 0.5 * (len - short_len - 1) as f32;
                        }
                    }
                }
                bias -= if len <= 2 {
                    1.6 * rank as f32
                } else {
                    0.8 * (rank as f32).ln_1p()
                };
                bias -= if weight < 50 {
                    2.5
                } else if weight < 500 {
                    0.8
                } else {
                    0.0
                };
                bias -= 6.0
                    * text
                        .chars()
                        .filter(|&c| decoder.model.char_to_token(c) <= 1)
                        .count() as f32;
                if let Some(second) = second {
                    bias += 0.0375 * decoder.aux.bigram_boost(first, second);
                    if len == MAX_CODE_LEN && rank == 0 {
                        bias += 0.45;
                    }
                }
                if custom {
                    bias += 2.5;
                }
                for parent in parents {
                    let mut preceding = parent
                        .text
                        .chars()
                        .rev()
                        .chain(decoder.context.iter().rev().copied());
                    let mut contextual_bias = bias;
                    if let Some(prev) = preceding.next() {
                        contextual_bias += 0.15 * decoder.aux.bigram_boost(prev, first);
                        if let Some(prev2) = preceding.next() {
                            contextual_bias += 0.15 * decoder.aux.trigram_boost(prev2, prev, first);
                        }
                    }
                    if personalize {
                        contextual_bias += personal.score(parent.personal_context, text);
                    }
                    let estimate = if n_chars == 1 {
                        decoder.model.score_next_char(&parent.state, first)
                    } else {
                        decoder.model.score_phrase_fast(&parent.state, text)
                            * (n_chars.min(MAX_CODE_LEN) as f32).powf(0.65)
                    };
                    let personal_estimate = if use_personal_states {
                        personal.state_bonus(parent.personal_context, first, &parent.state)
                    } else {
                        0.0
                    };
                    steps.push(Step {
                        parent,
                        text,
                        estimate: parent.score + contextual_bias + estimate + personal_estimate,
                        bias: contextual_bias,
                        code,
                        correction,
                    });
                }
            }
        }
        steps.sort_unstable_by(|a, b| b.estimate.total_cmp(&a.estimate));

        let mut paths: Vec<Path> = Vec::with_capacity(BEAM_WIDTH * 2);
        for step in steps.into_iter().take(BEAM_WIDTH * 2) {
            let mut state = step.parent.state.clone();
            let mut score = step.parent.score + step.bias;
            let mut personal_context = step.parent.personal_context;
            for ch in step.text.chars() {
                score += decoder.model.score_next_char(&state, ch);
                if use_personal_states {
                    score += personal.state_bonus(personal_context, ch, &state);
                }
                decoder
                    .model
                    .step_token(decoder.model.char_to_token(ch), &mut state);
                personal_context = personal_context.push(ch);
            }
            let mut text = step.parent.text.clone();
            text.push_str(step.text);
            let mut boundaries = step.parent.boundaries.clone();
            boundaries.push(Boundary {
                keys: end,
                text_bytes: text.len(),
                code: step.code,
                correction: step.correction,
            });
            let path = Path {
                text,
                score,
                boundaries,
                state,
                personal_context,
            };
            if let Some(existing) = paths.iter_mut().find(|p| p.text == path.text) {
                if path.score > existing.score {
                    *existing = path;
                }
            } else {
                paths.push(path);
            }
        }
        paths.sort_unstable_by(|a, b| b.score.total_cmp(&a.score));
        paths.truncate(BEAM_WIDTH);
        paths
    }
}
