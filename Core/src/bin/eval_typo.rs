use std::collections::BTreeMap;
use std::env;
use std::fs;
use std::path::PathBuf;
use wubi_core::code::PackedCode;
use wubi_core::config::{WubiConfig, WubiSchema};
use wubi_core::engine::{LmWeights, WubiEngine};
use wubi_core::format::{AuxView, DictView};
use wubi_core::typo::KeyLayout;

/// Deterministic xorshift64* PRNG (zero external dependencies)
struct Rng(u64);
impl Rng {
    fn new(seed: u64) -> Self {
        Self(seed.max(1))
    }
    fn next_u64(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }
    fn next_f32(&mut self) -> f32 {
        ((self.next_u64() >> 40) as f32) / ((1u32 << 24) as f32)
    }
    fn range(&mut self, n: usize) -> usize {
        if n <= 1 {
            0
        } else {
            (self.next_u64() as usize) % n
        }
    }
}

fn neighbor_keys(layout: &KeyLayout, ch: u8) -> Vec<u8> {
    let (cx0, cy0) = layout.center_of(ch);
    let mut out = Vec::new();
    for d in 0..25u8 {
        let k = b'a' + d;
        if k == ch {
            continue;
        }
        let (cx, cy) = layout.center_of(k);
        let dx = (cx - cx0).abs();
        let dy = (cy - cy0).abs();
        if (dy < 0.1 && dx <= 1.05) || (dy <= 1.05 && dx <= 0.85) {
            out.push(k);
        }
    }
    out
}

/// Segment a Chinese sentence into realistic Wubi tokens `(text, code)` using greedy phrase-first
/// matching (2..=4 char phrases that are #1 at their 4-letter code, else single chars with 2..=4
/// or 1-letter code).
fn segment_sentence(dict: &DictView, sent: &str) -> Vec<(String, String)> {
    let chars: Vec<char> = sent.chars().collect();
    let mut tokens = Vec::new();
    let mut i = 0usize;
    while i < chars.len() {
        let mut matched: Option<(usize, String, String)> = None;
        // Prefer 2..=4 char dictionary phrases when they are primary (#1) at their code
        for len in (2..=4).rev() {
            if i + len > chars.len() {
                continue;
            }
            let sub: String = chars[i..i + len].iter().collect();
            if let Some(code) = dict.encode_phrase(&sub) {
                let hits = dict.lookup_exact(code, false);
                if let Some(first) = hits.first() {
                    if first.text == sub {
                        matched = Some((len, sub, code.as_string()));
                        break;
                    }
                }
            }
        }
        if let Some((len, text, code)) = matched {
            tokens.push((text, code));
            i += len;
            continue;
        }
        // Fallback to single char (use primary short code if available, else full code)
        let ch = chars[i];
        let mut pushed = false;
        if let Some(meta) = dict.char_meta(ch) {
            let code = if !meta.primary_short_code.is_empty() {
                meta.primary_short_code
            } else if !meta.shortest_code.is_empty() {
                meta.shortest_code
            } else {
                meta.full_code
            };
            let cs = code.as_string();
            if !cs.is_empty() && cs.bytes().all(|b| (b'a'..=b'y').contains(&b)) {
                // Only keep if ch is top-1 at this code (realistic blind typing target)
                let hits = dict.lookup_exact(code, false);
                if hits.first().map(|e| e.text == ch.to_string()).unwrap_or(false) {
                    tokens.push((ch.to_string(), cs));
                    pushed = true;
                } else if !meta.full_code.is_empty() {
                    let fhits = dict.lookup_exact(meta.full_code, false);
                    let fcs = meta.full_code.as_string();
                    if fhits.first().map(|e| e.text == ch.to_string()).unwrap_or(false)
                        && fcs.bytes().all(|b| (b'a'..=b'y').contains(&b))
                    {
                        tokens.push((ch.to_string(), fcs));
                        pushed = true;
                    }
                }
            }
        }
        if !pushed {
            tokens.push((ch.to_string(), String::new()));
        }
        i += 1;
    }
    tokens
}

#[derive(Default, Clone, Debug)]
struct Metrics {
    // 1. Touch boundary slip onto a VALID colliding code (hardest disambiguation)
    touch_coll_n: usize,
    touch_coll_top1: usize,
    touch_coll_top3: usize,
    // 2. Touch boundary slip onto an EMPTY code (empty-code rescue)
    touch_empty_n: usize,
    touch_empty_top1: usize,
    touch_empty_top3: usize,
    // 3. Physical neighbor key typo (empty-code rescue)
    phys_empty_n: usize,
    phys_empty_top1: usize,
    phys_empty_top3: usize,
    // 4. Correct touch near border (0.36..0.46 toward neighbor, still on intended key): false positive rate!
    correct_border_n: usize,
    correct_border_fp: usize,
}

impl Metrics {
    fn add(&mut self, o: &Metrics) {
        self.touch_coll_n += o.touch_coll_n;
        self.touch_coll_top1 += o.touch_coll_top1;
        self.touch_coll_top3 += o.touch_coll_top3;
        self.touch_empty_n += o.touch_empty_n;
        self.touch_empty_top1 += o.touch_empty_top1;
        self.touch_empty_top3 += o.touch_empty_top3;
        self.phys_empty_n += o.phys_empty_n;
        self.phys_empty_top1 += o.phys_empty_top1;
        self.phys_empty_top3 += o.phys_empty_top3;
        self.correct_border_n += o.correct_border_n;
        self.correct_border_fp += o.correct_border_fp;
    }

    fn pct(a: usize, b: usize) -> f64 {
        if b == 0 {
            0.0
        } else {
            100.0 * (a as f64) / (b as f64)
        }
    }

    fn print_row(&self, label: &str) {
        println!(
            "{:<20} | TouchColl({:4}): T1={:5.2}% T3={:5.2}% | TouchEmpty({:4}): T1={:5.2}% T3={:5.2}% | PhysEmpty({:4}): T1={:5.2}% T3={:5.2}% | BorderFP({:4}): {:5.2}%",
            label,
            self.touch_coll_n,
            Self::pct(self.touch_coll_top1, self.touch_coll_n),
            Self::pct(self.touch_coll_top3, self.touch_coll_n),
            self.touch_empty_n,
            Self::pct(self.touch_empty_top1, self.touch_empty_n),
            Self::pct(self.touch_empty_top3, self.touch_empty_n),
            self.phys_empty_n,
            Self::pct(self.phys_empty_top1, self.phys_empty_n),
            Self::pct(self.phys_empty_top3, self.phys_empty_n),
            self.correct_border_n,
            Self::pct(self.correct_border_fp, self.correct_border_n),
        );
    }

    /// Combined validation objective (higher is better; penalizes false positives strongly)
    fn objective(&self) -> f64 {
        let tc1 = Self::pct(self.touch_coll_top1, self.touch_coll_n);
        let tc3 = Self::pct(self.touch_coll_top3, self.touch_coll_n);
        let te1 = Self::pct(self.touch_empty_top1, self.touch_empty_n);
        let pe1 = Self::pct(self.phys_empty_top1, self.phys_empty_n);
        let fp = Self::pct(self.correct_border_fp, self.correct_border_n);
        0.40 * tc1 + 0.15 * tc3 + 0.30 * te1 + 0.15 * pe1 - 2.5 * fp
    }
}

fn run_eval_with_engine(
    engine: &mut WubiEngine,
    sentences: &[(String, String)],
    seed: u64,
    max_per_domain: usize,
) -> (Metrics, BTreeMap<String, Metrics>) {
    let layout = KeyLayout::default();
    let mut rng = Rng::new(seed);
    let mut per_dom = BTreeMap::<String, Metrics>::new();
    let mut dom_sent_cnt = BTreeMap::<String, usize>::new();

    for (dom, sent) in sentences {
        let sc = dom_sent_cnt.entry(dom.clone()).or_insert(0);
        if *sc >= max_per_domain {
            continue;
        }
        *sc += 1;

        let tokens = {
            let d = engine.active_dict().unwrap();
            segment_sentence(d, sent)
        };
        let m = per_dom.entry(dom.clone()).or_default();
        let mut prefix_ctx = String::new();

        for (target_text, target_code) in tokens {
            let code_bytes = target_code.as_bytes();
            let code_len = code_bytes.len();

            if code_len >= 2 && code_len <= 4 {
                // Collect neighbor mutations classified into colliding vs empty
                let mut coll_muts = Vec::<(usize, u8)>::new();
                let mut empty_muts = Vec::<(usize, u8)>::new();
                {
                    let d = engine.active_dict().unwrap();
                    for pos in 0..code_len {
                        let orig = code_bytes[pos];
                        for nb in neighbor_keys(&layout, orig) {
                            let mut mut_code = code_bytes.to_vec();
                            mut_code[pos] = nb;
                            if let Some(pc) = PackedCode::from_bytes(&mut_code) {
                                let hits = d.lookup_exact(pc, false);
                                if hits.is_empty() {
                                    empty_muts.push((pos, nb));
                                } else if hits[0].text != target_text {
                                    coll_muts.push((pos, nb));
                                }
                            }
                        }
                    }
                }

                // 1) Touch Boundary Slip -> Colliding code
                if !coll_muts.is_empty() {
                    let (pos, nb) = coll_muts[rng.range(coll_muts.len())];
                    let alpha = 0.53 + rng.next_f32() * 0.08; // 0.53..0.61 past midpoint onto neighbor
                    let jitter_y = (rng.next_f32() - 0.5) * 0.12;
                    engine.clear_composition();
                    engine.set_recent_context(&prefix_ctx);
                    for j in 0..code_len {
                        let orig = code_bytes[j];
                        let (cx, cy) = layout.center_of(orig);
                        if j == pos {
                            let (nx, ny) = layout.center_of(nb);
                            let tx = cx + alpha * (nx - cx);
                            let ty = cy + alpha * (ny - cy) + jitter_y;
                            let _ = engine.push_touch_letter(nb, tx, ty, true, 1000 + j as u64 * 70);
                        } else {
                            let jx = (rng.next_f32() - 0.5) * 0.10;
                            let jy = (rng.next_f32() - 0.5) * 0.10;
                            let _ = engine.push_touch_letter(orig, cx + jx, cy + jy, true, 1000 + j as u64 * 70);
                        }
                    }
                    let cands = engine.all_candidates();
                    m.touch_coll_n += 1;
                    if cands.first().map(|c| c.text == target_text).unwrap_or(false) {
                        m.touch_coll_top1 += 1;
                    }
                    if cands.iter().take(3).any(|c| c.text == target_text) {
                        m.touch_coll_top3 += 1;
                    }
                }

                // 2) Touch Boundary Slip -> Empty code
                if !empty_muts.is_empty() {
                    let (pos, nb) = empty_muts[rng.range(empty_muts.len())];
                    let alpha = 0.54 + rng.next_f32() * 0.16; // 0.54..0.70 onto neighbor
                    let jitter_y = (rng.next_f32() - 0.5) * 0.12;
                    engine.clear_composition();
                    engine.set_recent_context(&prefix_ctx);
                    for j in 0..code_len {
                        let orig = code_bytes[j];
                        let (cx, cy) = layout.center_of(orig);
                        if j == pos {
                            let (nx, ny) = layout.center_of(nb);
                            let tx = cx + alpha * (nx - cx);
                            let ty = cy + alpha * (ny - cy) + jitter_y;
                            let _ = engine.push_touch_letter(nb, tx, ty, true, 1000 + j as u64 * 70);
                        } else {
                            let jx = (rng.next_f32() - 0.5) * 0.10;
                            let jy = (rng.next_f32() - 0.5) * 0.10;
                            let _ = engine.push_touch_letter(orig, cx + jx, cy + jy, true, 1000 + j as u64 * 70);
                        }
                    }
                    let cands = engine.all_candidates();
                    m.touch_empty_n += 1;
                    if cands.first().map(|c| c.text == target_text).unwrap_or(false) {
                        m.touch_empty_top1 += 1;
                    }
                    if cands.iter().take(3).any(|c| c.text == target_text) {
                        m.touch_empty_top3 += 1;
                    }

                    // 3a) Physical keyboard empty-code neighbor typo
                    engine.clear_composition();
                    engine.set_recent_context(&prefix_ctx);
                    for j in 0..code_len {
                        let ch = if j == pos { nb } else { code_bytes[j] };
                        let _ = engine.handle_key_event(0, Some(ch as char), false, 1000 + j as u64 * 70);
                    }
                    let pcands = engine.all_candidates();
                    m.phys_empty_n += 1;
                    if pcands.first().map(|c| c.text == target_text).unwrap_or(false) {
                        m.phys_empty_top1 += 1;
                    }
                    if pcands.iter().take(3).any(|c| c.text == target_text) {
                        m.phys_empty_top3 += 1;
                    }
                }

                // 4) Correct Touch near key border (0.36..0.46 toward neighbor -> still inside intended key!)
                //    Measures false-positive over-correction rate!
                if !coll_muts.is_empty() {
                    let (pos, nb) = coll_muts[rng.range(coll_muts.len())];
                    let alpha = 0.36 + rng.next_f32() * 0.10; // 0.36..0.46 (near border, still on intended key!)
                    engine.clear_composition();
                    engine.set_recent_context(&prefix_ctx);
                    for j in 0..code_len {
                        let orig = code_bytes[j];
                        let (cx, cy) = layout.center_of(orig);
                        if j == pos {
                            let (nx, ny) = layout.center_of(nb);
                            let tx = cx + alpha * (nx - cx);
                            let ty = cy + alpha * (ny - cy);
                            let _ = engine.push_touch_letter(orig, tx, ty, true, 1000 + j as u64 * 70);
                        } else {
                            let _ = engine.push_touch_letter(orig, cx, cy, true, 1000 + j as u64 * 70);
                        }
                    }
                    let cands = engine.all_candidates();
                    m.correct_border_n += 1;
                    if !cands.first().map(|c| c.text == target_text).unwrap_or(false) {
                        m.correct_border_fp += 1;
                    }
                }
            }

            prefix_ctx.push_str(&target_text);
        }
    }

    let mut total = Metrics::default();
    for m in per_dom.values() {
        total.add(m);
    }
    (total, per_dom)
}

fn load_sentences(path: &PathBuf) -> Vec<(String, String)> {
    let content = fs::read_to_string(path).unwrap_or_else(|e| panic!("read {}: {}", path.display(), e));
    let mut out = Vec::new();
    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let mut it = line.splitn(2, '\t');
        let Some(dom) = it.next() else { continue };
        let Some(sent) = it.next() else { continue };
        if !sent.is_empty() {
            out.push((dom.to_string(), sent.to_string()));
        }
    }
    out
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let mut dicts_dir = PathBuf::from("Resources/Dicts");
    let mut aux_path: Option<PathBuf> = None;
    let mut eval_tsv: Option<PathBuf> = None;
    let mut schema = WubiSchema::Wubi86;
    let mut max_per_domain = 250usize;
    let mut grid_search = false;
    let mut lm_w = LmWeights::default();

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--dicts-dir" => { dicts_dir = PathBuf::from(&args[i + 1]); i += 2; }
            "--aux" => { aux_path = Some(PathBuf::from(&args[i + 1])); i += 2; }
            "--eval" => { eval_tsv = Some(PathBuf::from(&args[i + 1])); i += 2; }
            "--schema" => { schema = WubiSchema::from_str_tag(&args[i + 1]); i += 2; }
            "--max-per-domain" => { max_per_domain = args[i + 1].parse().unwrap(); i += 2; }
            "--grid-search" => { grid_search = true; i += 1; }
            "--uni" => { lm_w.corpus_unigram_scale = args[i + 1].parse().unwrap(); i += 2; }
            "--dict-prior" => { lm_w.dict_prior_scale = args[i + 1].parse().unwrap(); i += 2; }
            "--bg" => { lm_w.bigram_scale = args[i + 1].parse().unwrap(); i += 2; }
            "--tg" => { lm_w.trigram_scale = args[i + 1].parse().unwrap(); i += 2; }
            "--int-bg" => { lm_w.internal_bigram_scale = args[i + 1].parse().unwrap(); i += 2; }
            "--spatial" => { lm_w.spatial_scale = args[i + 1].parse().unwrap(); i += 2; }
            other => {
                eprintln!("Unknown arg: {}", other);
                std::process::exit(1);
            }
        }
    }

    let eval_tsv = eval_tsv.expect("--eval <tsv> required");
    let aux_file = aux_path.unwrap_or_else(|| dicts_dir.join("wubi_aux.wbaux"));
    let dict_file = match schema {
        WubiSchema::Wubi86 => dicts_dir.join("wubi86.wbdict"),
        WubiSchema::Wubi98 => dicts_dir.join("wubi98.wbdict"),
        WubiSchema::Wubi06 => dicts_dir.join("wubi06.wbdict"),
    };

    let dict = DictView::open_mmap(&dict_file).expect("open dict");
    let aux = AuxView::open_mmap(&aux_file).expect("open aux");
    let stats = aux.stats();
    println!(
        "Loaded schema={} aux={} (py={}, uni={}, bi={}, tri={})",
        schema.as_tag(),
        aux_file.display(),
        stats.0,
        stats.1,
        stats.2,
        stats.3
    );

    let sentences = load_sentences(&eval_tsv);
    let mut cfg = WubiConfig::default();
    cfg.schema = schema;
    cfg.fourth_code_auto_commit = false;
    cfg.typo.enabled = true;
    cfg.typo.touch_hitbox_adapt = false;

    let mut engine = WubiEngine::new(cfg);
    engine.load_dict(schema, dict);
    engine.set_aux(aux);

    if grid_search {
        println!("Running validation grid search...");
        let mut best_obj = f64::NEG_INFINITY;
        let mut best_w = lm_w;
        for &dp in &[0.22f32, 0.30, 0.38] {
            for &cu in &[0.28f32, 0.40, 0.52] {
                for &bg in &[0.85f32, 1.05, 1.25] {
                    for &tg in &[0.75f32, 1.00, 1.25] {
                        let w = LmWeights {
                            spatial_scale: 2.05,
                            dict_prior_scale: dp,
                            corpus_unigram_scale: cu,
                            internal_bigram_scale: 0.30,
                            bigram_scale: bg,
                            trigram_scale: tg,
                            cross_trigram_scale: tg * 0.65,
                            phrase_bonus: 0.65,
                        };
                        engine.lm_weights = w;
                        let (tot, _) = run_eval_with_engine(&mut engine, &sentences, 20261119, max_per_domain);
                        let obj = tot.objective();
                        if obj > best_obj {
                            best_obj = obj;
                            best_w = w;
                            println!(
                                "NEW BEST obj={:6.2} (dp={:.2} cu={:.2} bg={:.2} tg={:.2}) -> TC1={:.2}% TC3={:.2}% TE1={:.2}% PE1={:.2}% FP={:.2}%",
                                obj,
                                dp,
                                cu,
                                bg,
                                tg,
                                Metrics::pct(tot.touch_coll_top1, tot.touch_coll_n),
                                Metrics::pct(tot.touch_coll_top3, tot.touch_coll_n),
                                Metrics::pct(tot.touch_empty_top1, tot.touch_empty_n),
                                Metrics::pct(tot.phys_empty_top1, tot.phys_empty_n),
                                Metrics::pct(tot.correct_border_fp, tot.correct_border_n),
                            );
                        }
                    }
                }
            }
        }
        println!("Best weights: {:?}", best_w);
    } else {
        engine.lm_weights = lm_w;
        let (total, per_dom) = run_eval_with_engine(&mut engine, &sentences, 20261119, max_per_domain);
        println!("----------------------------------------------------------------------------------------------------------------------------------");
        for (dom, m) in &per_dom {
            m.print_row(dom);
        }
        println!("----------------------------------------------------------------------------------------------------------------------------------");
        total.print_row("OVERALL");
        println!("Objective score: {:.2}", total.objective());
    }
}
