use std::path::PathBuf;
use std::time::Instant;
use wubi_core::config::{WubiConfig, WubiSchema};
use wubi_core::engine::{CandidateBadge, WubiEngine, KEY_BACKSPACE, KEY_RETURN, KEY_SPACE};
use wubi_core::format::{AuxView, DictView};
use wubi_core::user_data::UserStore;

fn dicts_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("Resources/Dicts")
}

#[test]
fn spaceless_personal_context_generalizes_beyond_the_shared_suffix() {
    let dir = dicts_dir();
    if !dir.join("wubi86.wbdict").exists() {
        return;
    }
    let config = WubiConfig {
        spaceless: true,
        auto_phrase: false,
        ..WubiConfig::default()
    };
    let mut engine = WubiEngine::new(config.clone());
    engine.load_dict(
        WubiSchema::Wubi86,
        DictView::open_mmap(dir.join("wubi86.wbdict")).unwrap(),
    );
    engine.set_aux(AuxView::open_mmap(dir.join("wubi_aux.wbaux")).unwrap());
    let enter = |engine: &mut WubiEngine, context: &str, code: &str| {
        engine.clear_composition();
        engine.set_recent_context(context);
        for (i, ch) in code.chars().enumerate() {
            engine.handle_key_event(0, Some(ch), false, 100 + i as u64 * 90);
        }
    };

    let legal = "法律团队为了明天的研讨会正在收集";
    let safety = "安全部门为了明天的检查会正在收集";
    for context in [legal, safety] {
        enter(&mut engine, context, "pvwguqou");
        assert_eq!(engine.preedit(), "安全资料");
    }
    for _ in 0..12 {
        for (context, preferred) in [
            ("法务团队为了下周的研讨会正在收集", "案例材料"),
            ("安全团队为了下周的检查会正在收集", "安全材料"),
        ] {
            enter(&mut engine, context, "pvwgsfou");
            let index = engine
                .all_candidates()
                .iter()
                .position(|candidate| candidate.text == preferred)
                .unwrap();
            let selected = engine.select_abs_candidate(index, 1_200).unwrap();
            assert_eq!(selected.commit_text, preferred);
        }
    }

    let path = std::env::temp_dir().join(format!("wubi-personal-{}.tsv", std::process::id()));
    engine.user.save_file(&path).unwrap();
    engine.user = UserStore::load_file(&path).unwrap();

    // Neither entire prefix nor the "资料" ending was seen during training.
    // The prefixes share the final four characters, but the RWKV memories differ.
    for code in ["pvwguqou", "ovwguqou"] {
        enter(&mut engine, legal, code);
        assert_eq!(engine.preedit(), "案例资料");
        assert_eq!(engine.all_candidates()[0].is_exact, code.starts_with('p'));
        enter(&mut engine, safety, code);
        assert_eq!(engine.preedit(), "安全资料");
    }

    // An incompatible neural checkpoint must fall back to the same short statistics.
    let saved = std::fs::read_to_string(&path).unwrap();
    assert!(saved.lines().any(|line| line.starts_with("CONT_MODEL\t")));
    let short_only: String = saved.lines()
        .filter(|line| !line.starts_with("CONT_MODEL\t"))
        .flat_map(|line| line.chars().chain(['\n']))
        .collect();
    std::fs::write(&path, short_only).unwrap();
    engine.user = UserStore::load_file(&path).unwrap();
    std::fs::remove_file(path).unwrap();
    for context in [legal, safety] {
        enter(&mut engine, context, "pvwguqou");
        assert_eq!(engine.preedit(), "安全资料");
    }
}

#[test]
fn spaceless_touch_correction_learns_confirmed_code() {
    let dir = dicts_dir();
    if !dir.join("wubi86.wbdict").exists() {
        return;
    }
    let mut config = WubiConfig { spaceless: true, ..WubiConfig::default() };
    let mut engine = WubiEngine::new(config.clone());
    engine.load_dict(WubiSchema::Wubi86, DictView::open_mmap(dir.join("wubi86.wbdict")).unwrap());
    engine.set_aux(AuxView::open_mmap(dir.join("wubi_aux.wbaux")).unwrap());
    let taps = [
        (b'y', 4.54, 0.03),
        (b'r', 3.02, 0.02),
        (b'w', 1.01, -0.02),
        (b'u', 5.98, 0.01),
        (b'j', 6.5, 1.0),
    ];
    let type_taps = |engine: &mut WubiEngine| {
        for (i, &(letter, x, y)) in taps.iter().enumerate() {
            engine.push_touch_letter(letter, x, y, false, 100 + i as u64 * 70);
        }
    };
    type_taps(&mut engine);
    assert_eq!(engine.raw_code(), "yrwuj");
    assert_eq!(engine.preedit(), "我们是");
    let first = &engine.all_candidates()[0];
    assert_eq!(first.badge, CandidateBadge::TypoCorrected);
    assert_eq!(first.comment, "trwu");
    assert!(!first.is_exact);
    assert_eq!(engine.user.touch_profile.offset_for(b't'), (0.0, 0.0));

    engine.handle_key_event(KEY_BACKSPACE, None, false, 500);
    assert_eq!(engine.preedit(), "我们");
    engine.push_touch_letter(b'j', 6.5, 1.0, false, 570);
    let result = engine.handle_key_event(KEY_SPACE, Some(' '), false, 640);
    assert_eq!(result.commit_text, "我们是");
    assert!(engine.user.touch_profile.offset_for(b't').0 > 0.07);
    assert_eq!(engine.user.touch_profile.keys[(b'j' - b'a') as usize].samples, 1);
    assert_eq!(engine.user.touch_profile.keys[(b'y' - b'a') as usize].samples, 0);

    engine.clear_context();
    config.typo.enabled = false;
    engine.set_config(config);
    type_taps(&mut engine);
    assert_eq!(engine.raw_code(), "yrwuj");
    assert_ne!(engine.preedit(), "我们是");
    assert!(engine.all_candidates().iter().all(|candidate| candidate.is_exact));
    let raw = engine.handle_key_event(KEY_RETURN, None, false, 900);
    assert_eq!(raw.commit_text, "yrwuj");
}

#[test]
fn real_dicts_latency_schemas_and_typo_correction() {
    let dir = dicts_dir();
    if !dir.join("wubi86.wbdict").exists() {
        return;
    }

    let t0 = Instant::now();
    let d86 = DictView::open_mmap(dir.join("wubi86.wbdict")).unwrap();
    let d98 = DictView::open_mmap(dir.join("wubi98.wbdict")).unwrap();
    let d06 = DictView::open_mmap(dir.join("wubi06.wbdict")).unwrap();
    let aux = AuxView::open_mmap(dir.join("wubi_aux.wbaux")).unwrap();
    let mmap_us = t0.elapsed().as_micros();
    let (py_cnt, uni_cnt, bi_cnt, tri_cnt) = aux.stats();
    println!(
        "Cold-start mmap of 86 + 98 + 06 + aux (py={}, uni={}, bi={}, tri={}, neural={}) took: {} us",
        py_cnt,
        uni_cnt,
        bi_cnt,
        tri_cnt,
        aux.has_neural(),
        mmap_us
    );
    assert!(mmap_us < 10_000, "mmap should be sub-millisecond to few ms");
    assert!(aux.has_unigrams(), "expected WBAUX002/WBAUX003 with corpus unigrams");
    assert!(aux.has_neural(), "expected WBAUX003 with Micro-RWKV-7 neural blob");
    assert!(uni_cnt >= 7_500 && bi_cnt >= 50_000 && tri_cnt >= 25_000);
    assert!(aux.trigram_boost('输', '入', '法') > 0.5);
    assert!(aux.trigram_boost('小', '红', '书') > 0.5);
    assert!(aux.bigram_boost('模', '型') > 1.0);

    // Verify exact INT8 numerical parity against Python QAT reference ("今天天气真" -> 好/热 vs 油/突)
    {
        let nv = aux.neural_view().expect("neural_view");
        let mut tracker = wubi_core::neural::NeuralContextTracker::default();
        tracker.init_with_model(&nv);
        tracker.commit_cjk_str(&nv, "今天天气真");
        let s_hao = nv.score_next_char(&tracker.active, '好');
        let s_re = nv.score_next_char(&tracker.active, '热');
        let s_you = nv.score_next_char(&tracker.active, '油');
        let s_tu = nv.score_next_char(&tracker.active, '突');
        println!(
            "RWKV-7 parity check '今天天气真' -> 好={:.6}, 热={:.6}, 油={:.6}, 突={:.6}",
            s_hao, s_re, s_you, s_tu
        );
        assert!((s_hao - (-0.558271)).abs() < 2e-4, "hao parity mismatch: {}", s_hao);
        assert!((s_re - (-6.590938)).abs() < 2e-4, "re parity mismatch: {}", s_re);
        assert!((s_you - (-9.325247)).abs() < 2e-4, "you parity mismatch: {}", s_you);
        assert!((s_tu - (-8.358400)).abs() < 2e-4, "tu parity mismatch: {}", s_tu);

        // Verify modern tech entity awareness in Micro-RWKV-7 ("大模" -> '型')
        tracker.init_with_model(&nv);
        tracker.commit_cjk_str(&nv, "大模");
        let s_xing = nv.score_next_char(&tracker.active, '型');
        println!("RWKV-7 modern tech check '大模' -> 型={:.4}", s_xing);
        assert!(s_xing > -2.0, "expected RWKV-7 to strongly predict '型' after '大模', got {}", s_xing);
    }

    // Verify authentic differences across 86, 98, and 06 (新世纪)!
    // E.g. '码': 86 = dcg, 98 = dcg, '软': 86 = lqw, 98 = lqw; '气': 86 = rnb, 98 = rty, 06 = rty/rn...
    let code_86_jsj = d86.encode_phrase("计算机").unwrap().as_string();
    let code_98_jsj = d98.encode_phrase("计算机").unwrap().as_string();
    let code_06_jsj = d06.encode_phrase("计算机").unwrap().as_string();
    println!(
        "Phrase '计算机' codes -> 86: {}, 98: {}, 06: {}",
        code_86_jsj, code_98_jsj, code_06_jsj
    );

    let mut engine = WubiEngine::new(WubiConfig::default());
    engine.load_dict(WubiSchema::Wubi86, d86);
    engine.load_dict(WubiSchema::Wubi98, d98);
    engine.load_dict(WubiSchema::Wubi06, d06);
    engine.set_aux(aux);

    // Benchmark 1000 full 4-keystroke sequences WITH statistical typo-correction enabled!
    let bench_start = Instant::now();
    let iterations = 250;
    for _ in 0..iterations {
        for ch in ['t', 'r', 'w', 'u'] {
            let _ = engine.handle_key_event(0, Some(ch), false, 1000);
        }
        engine.clear_composition();
    }
    let avg_keystroke_us = bench_start.elapsed().as_secs_f64() * 1e6 / ((iterations * 4) as f64);
    println!(
        "Average full keystroke + 24-beam Bayesian typo decode latency: {:.2} us",
        avg_keystroke_us
    );
    assert!(avg_keystroke_us < 250.0);

    // Real touchscreen slip test on 136k-entry Wubi86:
    // User wants "我们" (`trwu`), thumb hits right edge of `t` (4.0,0) -> (4.54, 0.03) (`y`)
    let _ = engine.push_touch_letter(b'y', 4.54, 0.03, true, 100);
    let _ = engine.push_touch_letter(b'r', 3.02, 0.02, true, 170);
    let _ = engine.push_touch_letter(b'w', 1.01, -0.02, true, 240);
    let _ = engine.push_touch_letter(b'u', 5.98, 0.01, true, 310);
    let top_cands: Vec<String> = engine
        .page_candidates()
        .iter()
        .map(|c| format!("{}[{} {:.0}%]", c.text, c.comment, c.confidence * 100.0))
        .collect();
    println!("Touch slip 'yrwu' (near t/y border) -> {:?}", top_cands);
    assert!(
        engine.page_candidates().iter().take(2).any(|c| c.text == "我们"),
        "expected '我们' in top-2 candidates for touch slip yrwu, got {:?}",
        top_cands
    );
    engine.clear_composition();

    // Switch to 98 and 06 and verify instant lookup
    engine.set_schema(WubiSchema::Wubi98);
    let _ = engine.handle_key_event(0, Some('q'), false, 500);
    assert_eq!(engine.page_candidates()[0].text, "我");
    engine.clear_composition();

    engine.set_schema(WubiSchema::Wubi06);
    let _ = engine.handle_key_event(0, Some('q'), false, 600);
    assert_eq!(engine.page_candidates()[0].text, "我");
    engine.clear_composition();

    // Test lightweight N-gram idle next-word prediction & latency
    engine.set_schema(WubiSchema::Wubi86);
    let samples = [
        "",
        "我",
        "我们",
        "今天",
        "这个",
        "不知",
        "小红",
        "大模",
        "没问",
        "真的",
        "为什么",
        "但是",
        "如果",
        "现在",
        "输入",
        "情绪",
        "性价",
        "绷不",
        "最近",
        "可以",
    ];
    let pt0 = Instant::now();
    for s in samples {
        engine.set_recent_context(s);
        let preds = engine.predict_next_words(8);
        println!("Predict after {:<6} -> {:?}", s, preds);
        assert_eq!(preds.len(), 8);
    }
    let avg_pred_us = pt0.elapsed().as_secs_f64() * 1e6 / (samples.len() as f64);
    println!("Average idle next-word prediction latency: {:.2} us", avg_pred_us);
    assert!(avg_pred_us < 1500.0, "prediction latency too high: {:.2} us", avg_pred_us);

    // Verify specific high-confidence completions
    engine.set_recent_context("不知");
    assert!(engine.predict_next_words(8).iter().take(3).any(|w| w == "道"));
    engine.set_recent_context("小红");
    assert!(engine.predict_next_words(8).iter().take(3).any(|w| w == "书"));
    engine.set_recent_context("大模");
    assert!(engine.predict_next_words(8).iter().take(3).any(|w| w == "型"));
    engine.set_recent_context("输入");
    assert!(engine.predict_next_words(8).iter().take(4).any(|w| w == "法"));

    // Test LM-guided missed-space correction on real Wubi86 + Micro-RWKV-7:
    // 1) 3-code + 4-code (empty at key #4): "周末我想" + 去(fcu) + [no space] + 爬山(rhmm) -> "去爬山"
    engine.clear_composition();
    engine.set_recent_context("这个周末我想");
    let mut got = String::new();
    for (i, ch) in "fcurhmm".chars().enumerate() {
        let out = engine.handle_key_event(0, Some(ch), false, 2000 + i as u64 * 60);
        assert!(!out.bell, "unexpected bell on fcurhmm at {}", ch);
        got.push_str(&out.commit_text);
    }
    if engine.is_composing() {
        let out = engine.handle_key_event(wubi_core::engine::KEY_SPACE, Some(' '), false, 2500);
        got.push_str(&out.commit_text);
    }
    assert_eq!(got, "去爬山", "expected empty-collision missed-space rescue '去爬山', got '{}'", got);

    // 2) 3-code + 4-code (colliding 4-code exact match at key #4!):
    //    "我们一起" + 去(fcu) + [no space] + 吃饭(ktqn) -> `fcuk` collides in Wubi86, resolved at Key #5!
    engine.clear_composition();
    engine.set_recent_context("今天天气真好我们一起");
    let mut got2 = String::new();
    for (i, ch) in "fcuktqn".chars().enumerate() {
        let out = engine.handle_key_event(0, Some(ch), false, 3000 + i as u64 * 60);
        got2.push_str(&out.commit_text);
    }
    if engine.is_composing() {
        let out = engine.handle_key_event(wubi_core::engine::KEY_SPACE, Some(' '), false, 3600);
        got2.push_str(&out.commit_text);
    }
    assert_eq!(got2, "去吃饭", "expected colliding missed-space rescue '去吃饭', got '{}'", got2);

    // 3) 3-code + 1-code: "你觉得这家" + 店(yhk) + [no space] + 的(r) + Space -> "店的"
    engine.clear_composition();
    engine.set_recent_context("你觉得这家");
    let mut got3 = String::new();
    for (i, ch) in "yhkr".chars().enumerate() {
        let out = engine.handle_key_event(0, Some(ch), false, 4000 + i as u64 * 60);
        got3.push_str(&out.commit_text);
    }
    let out3_sp = engine.handle_key_event(wubi_core::engine::KEY_SPACE, Some(' '), false, 4300);
    got3.push_str(&out3_sp.commit_text);
    assert_eq!(got3, "店的", "expected 3+1 missed-space rescue '店的', got '{}'", got3);
}
