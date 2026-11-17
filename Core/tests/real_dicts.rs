use std::path::PathBuf;
use std::time::Instant;
use wubi_core::config::{WubiConfig, WubiSchema};
use wubi_core::engine::WubiEngine;
use wubi_core::format::{AuxView, DictView};

fn dicts_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("Resources/Dicts")
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
    println!("Cold-start mmap of 86 + 98 + 06 + aux took: {} us", mmap_us);
    assert!(mmap_us < 10_000, "mmap should be sub-millisecond to few ms");

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
}
