use std::collections::HashMap;
use std::env;
use std::fs::{self, File};
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::path::{Path, PathBuf};

fn is_bmp_cjk(ch: char) -> bool {
    let u = ch as u32;
    (0x4E00..=0x9FFF).contains(&u) || (0x3400..=0x4DBF).contains(&u)
}

#[inline]
fn bi_key(c1: char, c2: char) -> u64 {
    ((c1 as u64) << 32) | (c2 as u64)
}

#[inline]
fn tri_key(c0: char, c1: char, c2: char) -> u64 {
    ((c0 as u64) << 32) | ((c1 as u64) << 16) | (c2 as u64)
}

struct GroupSpec {
    name: &'static str,
    path: Option<PathBuf>,
    target_weight: f64,
}

fn count_group_pass1(
    path: &Path,
    raw_uni: &mut HashMap<u32, u64>,
    raw_bi: &mut HashMap<u64, u64>,
) -> u64 {
    let file = File::open(path).unwrap_or_else(|e| panic!("open {}: {}", path.display(), e));
    let reader = BufReader::with_capacity(1 << 20, file);
    let mut chars_buf = Vec::<char>::with_capacity(256);
    let mut total_chars = 0u64;

    for line_res in reader.lines() {
        let Ok(line) = line_res else { continue };
        chars_buf.clear();
        for ch in line.chars() {
            if is_bmp_cjk(ch) {
                chars_buf.push(ch);
            }
        }
        let n = chars_buf.len();
        if n < 2 {
            continue;
        }
        total_chars += n as u64;
        for &ch in &chars_buf {
            *raw_uni.entry(ch as u32).or_insert(0) += 1;
        }
        for w in chars_buf.windows(2) {
            *raw_bi.entry(bi_key(w[0], w[1])).or_insert(0) += 1;
        }
    }
    total_chars
}

fn accumulate_group_pass2(
    path: &Path,
    scale: f64,
    raw_bi: &HashMap<u64, u64>,
    uni_mass: &mut HashMap<u32, f64>,
    bi_mass: &mut HashMap<u64, f64>,
    left_mass: &mut HashMap<u32, f64>,
    tri_stats: &mut HashMap<u64, (u32, f64)>,
) {
    let file = File::open(path).unwrap_or_else(|e| panic!("open {}: {}", path.display(), e));
    let reader = BufReader::with_capacity(1 << 20, file);
    let mut chars_buf = Vec::<char>::with_capacity(256);

    for line_res in reader.lines() {
        let Ok(line) = line_res else { continue };
        chars_buf.clear();
        for ch in line.chars() {
            if is_bmp_cjk(ch) {
                chars_buf.push(ch);
            }
        }
        let n = chars_buf.len();
        if n < 2 {
            continue;
        }
        for &ch in &chars_buf {
            *uni_mass.entry(ch as u32).or_insert(0.0) += scale;
        }
        for w in chars_buf.windows(2) {
            let k = bi_key(w[0], w[1]);
            *bi_mass.entry(k).or_insert(0.0) += scale;
            *left_mass.entry(w[0] as u32).or_insert(0.0) += scale;
        }
        if n >= 3 {
            for w in chars_buf.windows(3) {
                let k01 = bi_key(w[0], w[1]);
                let k12 = bi_key(w[1], w[2]);
                // Apriori pruning: a trigram can only reach raw_count >= 4 if both sub-bigrams have >= 4
                if raw_bi.get(&k01).copied().unwrap_or(0) >= 4
                    && raw_bi.get(&k12).copied().unwrap_or(0) >= 4
                {
                    let tk = tri_key(w[0], w[1], w[2]);
                    let e = tri_stats.entry(tk).or_insert((0, 0.0));
                    e.0 = e.0.saturating_add(1);
                    e.1 += scale;
                }
            }
        }
    }
}

fn add_rime_dict_backoff(
    raw_tables_dir: &Path,
    target_backoff_mass: f64,
    raw_uni: &mut HashMap<u32, u64>,
    raw_bi: &mut HashMap<u64, u64>,
    uni_mass: &mut HashMap<u32, f64>,
    bi_mass: &mut HashMap<u64, f64>,
    left_mass: &mut HashMap<u32, f64>,
) {
    let mut phrase_rows = Vec::<(Vec<char>, f64)>::new();
    let mut sum_w = 0.0f64;

    for rel in [
        "wubi86/wubi86.dict.yaml",
        "wubi98/wubi98.dict.yaml",
        "wubi06/wubi06.dict.yaml",
    ] {
        let p = raw_tables_dir.join(rel);
        let Ok(content) = fs::read_to_string(&p) else {
            continue;
        };
        let mut in_body = false;
        let mut max_wt = 0u64;
        let mut rows = Vec::<(String, u64)>::new();
        for raw_line in content.lines() {
            let line = raw_line.trim();
            if !in_body {
                if line == "..." {
                    in_body = true;
                }
                continue;
            }
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let parts: Vec<&str> = line.split('\t').collect();
            if parts.len() < 2 {
                continue;
            }
            let text = parts[0].trim();
            let code = parts[1].trim();
            if text.is_empty() || code.contains('z') {
                continue;
            }
            let wt = parts
                .get(2)
                .and_then(|s| s.trim().parse::<u64>().ok())
                .unwrap_or(0);
            if wt > max_wt {
                max_wt = wt;
            }
            rows.push((text.to_string(), wt));
        }
        let scale: u64 = if max_wt > 0 && max_wt < 10_000_000 {
            100_000
        } else {
            1
        };
        for (text, raw_wt) in rows {
            let chars: Vec<char> = text.chars().filter(|&c| is_bmp_cjk(c)).collect();
            if chars.len() < 2 {
                continue;
            }
            let w = (raw_wt.saturating_mul(scale) as f64).max(1000.0).powf(0.55);
            sum_w += w * ((chars.len() - 1) as f64);
            phrase_rows.push((chars, w));
        }
    }

    if sum_w <= 0.0 || target_backoff_mass <= 0.0 {
        return;
    }
    let norm = target_backoff_mass / sum_w;
    for (chars, w) in phrase_rows {
        let sw = w * norm;
        for &c in &chars {
            *uni_mass.entry(c as u32).or_insert(0.0) += sw;
            *raw_uni.entry(c as u32).or_insert(0) += 1;
        }
        for win in chars.windows(2) {
            let k = bi_key(win[0], win[1]);
            *bi_mass.entry(k).or_insert(0.0) += sw;
            *left_mass.entry(win[0] as u32).or_insert(0.0) += sw;
            let rc = raw_bi.entry(k).or_insert(0);
            if *rc < 3 {
                *rc += 1;
            }
        }
    }
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let mut formal_path: Option<PathBuf> = None;
    let mut community_path: Option<PathBuf> = None;
    let mut social_path: Option<PathBuf> = None;
    let mut raw_tables_dir: Option<PathBuf> = None;
    let mut out_dir: Option<PathBuf> = None;

    let mut w_formal = 0.40f64;
    let mut w_community = 0.30f64;
    let mut w_social = 0.30f64;
    let mut max_upsample = 4.0f64;
    let mut backoff_ratio = 0.025f64;
    let mut alpha_bi = 40.0f64;
    let mut beta_tri = 20.0f64;
    let mut max_unigrams = 12_000usize;
    let mut max_bigrams = 260_000usize;
    let mut max_trigrams = 150_000usize;

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--formal" => { formal_path = Some(PathBuf::from(&args[i + 1])); i += 2; }
            "--community" => { community_path = Some(PathBuf::from(&args[i + 1])); i += 2; }
            "--social" => { social_path = Some(PathBuf::from(&args[i + 1])); i += 2; }
            "--raw-tables" => { raw_tables_dir = Some(PathBuf::from(&args[i + 1])); i += 2; }
            "--out-dir" => { out_dir = Some(PathBuf::from(&args[i + 1])); i += 2; }
            "--w-formal" => { w_formal = args[i + 1].parse().unwrap(); i += 2; }
            "--w-community" => { w_community = args[i + 1].parse().unwrap(); i += 2; }
            "--w-social" => { w_social = args[i + 1].parse().unwrap(); i += 2; }
            "--max-upsample" => { max_upsample = args[i + 1].parse().unwrap(); i += 2; }
            "--backoff-ratio" => { backoff_ratio = args[i + 1].parse().unwrap(); i += 2; }
            "--alpha-bi" => { alpha_bi = args[i + 1].parse().unwrap(); i += 2; }
            "--beta-tri" => { beta_tri = args[i + 1].parse().unwrap(); i += 2; }
            "--max-unigrams" => { max_unigrams = args[i + 1].parse().unwrap(); i += 2; }
            "--max-bigrams" => { max_bigrams = args[i + 1].parse().unwrap(); i += 2; }
            "--max-trigrams" => { max_trigrams = args[i + 1].parse().unwrap(); i += 2; }
            other => {
                eprintln!("Unknown arg: {}", other);
                std::process::exit(1);
            }
        }
    }

    let out_dir = out_dir.expect("--out-dir is required");
    fs::create_dir_all(&out_dir).expect("create out_dir");

    let groups = [
        GroupSpec { name: "formal", path: formal_path, target_weight: w_formal },
        GroupSpec { name: "community", path: community_path, target_weight: w_community },
        GroupSpec { name: "social", path: social_path, target_weight: w_social },
    ];

    // Pass 1: count raw unweighted chars, unigrams, and bigrams per group
    let mut raw_uni = HashMap::<u32, u64>::with_capacity(16_000);
    let mut raw_bi = HashMap::<u64, u64>::with_capacity(2_500_000);
    let mut group_counts = Vec::<(&'static str, PathBuf, u64, f64)>::new();
    let mut total_raw_chars = 0u64;

    for g in groups {
        if let Some(p) = g.path {
            if p.exists() {
                let c = count_group_pass1(&p, &mut raw_uni, &mut raw_bi);
                println!("[pass1] {:<10}: {:10} CJK chars ({})", g.name, c, p.display());
                total_raw_chars += c;
                group_counts.push((g.name, p, c, g.target_weight));
            }
        }
    }
    assert!(total_raw_chars > 0, "no training corpus data found");
    println!(
        "[pass1] total raw CJK chars: {}, unique unigrams: {}, unique bigrams: {}",
        total_raw_chars,
        raw_uni.len(),
        raw_bi.len()
    );

    // Compute domain-balanced scales (capped at max_upsample to avoid amplifying small-sample noise)
    let weight_sum: f64 = group_counts.iter().map(|x| x.3).sum();
    let n_eff = total_raw_chars as f64;
    let mut group_scales = Vec::<(&'static str, PathBuf, f64)>::new();
    for (name, p, cnt, tw) in group_counts {
        if cnt == 0 {
            continue;
        }
        let desired_mass = n_eff * (tw / weight_sum);
        let scale = (desired_mass / (cnt as f64)).clamp(0.20, max_upsample);
        let eff_mass = (cnt as f64) * scale;
        println!(
            "[mix]   {:<10}: raw={:.2}M, scale={:.3}x -> eff={:.2}M",
            name,
            cnt as f64 / 1e6,
            scale,
            eff_mass / 1e6
        );
        group_scales.push((name, p, scale));
    }

    // Pass 2: accumulate domain-weighted unigrams, bigrams, and apriori-pruned trigrams
    let mut uni_mass = HashMap::<u32, f64>::with_capacity(raw_uni.len());
    let mut bi_mass = HashMap::<u64, f64>::with_capacity(raw_bi.len());
    let mut left_mass = HashMap::<u32, f64>::with_capacity(raw_uni.len());
    let mut tri_stats = HashMap::<u64, (u32, f64)>::with_capacity(3_000_000);

    for (name, p, scale) in &group_scales {
        accumulate_group_pass2(
            p,
            *scale,
            &raw_bi,
            &mut uni_mass,
            &mut bi_mass,
            &mut left_mass,
            &mut tri_stats,
        );
        println!(
            "[pass2] finished {:<10} (tracked trigrams: {})",
            name,
            tri_stats.len()
        );
    }

    let eff_total_before_backoff: f64 = uni_mass.values().sum();
    if let Some(rt_dir) = raw_tables_dir.as_deref() {
        let backoff_mass = eff_total_before_backoff * backoff_ratio;
        add_rime_dict_backoff(
            rt_dir,
            backoff_mass,
            &mut raw_uni,
            &mut raw_bi,
            &mut uni_mass,
            &mut bi_mass,
            &mut left_mass,
        );
        println!(
            "[backoff] added {:.2}M effective mass ({:.1}%) from Rime Wubi phrase tables",
            backoff_mass / 1e6,
            backoff_ratio * 100.0
        );
    }

    // 1. Compute smoothed Unigram probabilities & scores
    let total_uni: f64 = uni_mass.values().sum();
    let vocab_f = uni_mass.len().max(1) as f64;
    let mut p_uni = HashMap::<u32, f64>::with_capacity(uni_mass.len());
    let mut scored_uni = Vec::<(u32, f64, f64)>::with_capacity(uni_mass.len());

    for (&cp, &m) in &uni_mass {
        let rc = raw_uni.get(&cp).copied().unwrap_or(0);
        let p = (m + 0.5) / (total_uni + 0.5 * vocab_f);
        p_uni.insert(cp, p);
        if rc >= 3 {
            let score = (p.ln() + 14.0).clamp(0.0, 14.0);
            scored_uni.push((cp, m, score));
        }
    }
    scored_uni.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    scored_uni.truncate(max_unigrams);

    // 2. Compute Dirichlet-smoothed Bigram PMI + store P_bi for trigram residual lift
    let mut p_bi_map = HashMap::<u64, f64>::with_capacity(raw_bi.len() / 2);
    let mut scored_bi = Vec::<(u64, f64, f64)>::with_capacity(max_bigrams * 2);

    for (&k, &bm) in &bi_mass {
        let rc = raw_bi.get(&k).copied().unwrap_or(0);
        if rc < 3 {
            continue;
        }
        let c1 = (k >> 32) as u32;
        let c2 = (k & 0xFFFF_FFFF) as u32;
        let lm = left_mass.get(&c1).copied().unwrap_or(1.0);
        let pu2 = p_uni.get(&c2).copied().unwrap_or(1e-7);
        let p_bi = (bm + alpha_bi * pu2) / (lm + alpha_bi);
        if rc >= 4 {
            p_bi_map.insert(k, p_bi);
        }
        let pmi = (p_bi / pu2).ln();
        if pmi >= 0.18 {
            let boost = pmi.clamp(0.18, 5.50);
            let gain = bm.powf(0.85) * boost;
            scored_bi.push((k, gain, boost));
        }
    }
    scored_bi.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    scored_bi.truncate(max_bigrams);

    // 3. Compute Dirichlet-smoothed Trigram residual lift over Bigram
    let mut scored_tri = Vec::<(u64, f64, f64)>::with_capacity(max_trigrams * 2);
    for (tk, (rc, tm)) in tri_stats {
        if rc < 4 {
            continue;
        }
        let c0 = ((tk >> 32) & 0xFFFF) as u32;
        let c1 = ((tk >> 16) & 0xFFFF) as u32;
        let c2 = (tk & 0xFFFF) as u32;
        let k01 = ((c0 as u64) << 32) | (c1 as u64);
        let k12 = ((c1 as u64) << 32) | (c2 as u64);
        let c01_mass = bi_mass.get(&k01).copied().unwrap_or(1.0);
        let p_bi_12 = p_bi_map
            .get(&k12)
            .copied()
            .unwrap_or_else(|| p_uni.get(&c2).copied().unwrap_or(1e-7));
        let p_tri = (tm + beta_tri * p_bi_12) / (c01_mass + beta_tri);
        let lift = (p_tri / p_bi_12).ln();
        if lift >= 0.35 {
            let boost = lift.clamp(0.35, 5.00);
            let gain = tm.powf(0.85) * boost;
            scored_tri.push((tk, gain, boost));
        }
    }
    scored_tri.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    scored_tri.truncate(max_trigrams);

    // Write output TSVs
    {
        let mut w = BufWriter::new(File::create(out_dir.join("unigrams.tsv")).unwrap());
        for (cp, _, score) in &scored_uni {
            if let Some(ch) = char::from_u32(*cp) {
                writeln!(w, "{}\t{:.4}", ch, score).unwrap();
            }
        }
    }
    {
        let mut w = BufWriter::new(File::create(out_dir.join("bigrams.tsv")).unwrap());
        for (k, _, boost) in &scored_bi {
            let c1 = char::from_u32((*k >> 32) as u32).unwrap();
            let c2 = char::from_u32((*k & 0xFFFF_FFFF) as u32).unwrap();
            writeln!(w, "{}{}\t{:.4}", c1, c2, boost).unwrap();
        }
    }
    {
        let mut w = BufWriter::new(File::create(out_dir.join("trigrams.tsv")).unwrap());
        for (tk, _, boost) in &scored_tri {
            let c0 = char::from_u32(((*tk >> 32) & 0xFFFF) as u32).unwrap();
            let c1 = char::from_u32(((*tk >> 16) & 0xFFFF) as u32).unwrap();
            let c2 = char::from_u32((*tk & 0xFFFF) as u32).unwrap();
            writeln!(w, "{}{}{}\t{:.4}", c0, c1, c2, boost).unwrap();
        }
    }

    println!(
        "[done] wrote {} unigrams, {} bigrams, {} trigrams to {}",
        scored_uni.len(),
        scored_bi.len(),
        scored_tri.len(),
        out_dir.display()
    );
}
