#!/usr/bin/env python3
"""
Extract, clean, deduplicate, and split multi-domain Chinese corpora for Formordo LM training.

Sources supported (all optional; missing files are skipped cleanly):
  1. zhwiki_00002.parquet   - Wikimedia Chinese Wikipedia (formal base, converted t2s)
  2. zhihu_part*.jsonl.zst  - KrisTHL181/zhihu-qa (filtered to 2025-2026 answers)
  3. zhihu_16k.zip          - nlgandnlu/ZHIHU-16K (13-topic Q&A + discussions)
  4. tieba/*.json           - Orphanage/Baidu_Tieba_KangYaBeiGuo (2025 posts + replies)
  5. rednote_notes.csv      - FreshCrawl/rednote-xiaohongshu-notes (lifestyle notes)
  6. xhs_comments.csv       - xinjiexinjie/socialbots (2025 Xiaohongshu comments)
  7. extra_social/*.txt     - Optional extra UTF-8 text files (e.g. Bilibili comments)

Outputs in --out-dir:
  - clean/<group>_train.txt (one clean CJK run per line, groups: formal, community, social)
  - eval/val_sentences.tsv  (<domain>\t<sentence>)
  - eval/test_sentences.tsv (<domain>\t<sentence>)
  - corpus_stats.json
"""

from __future__ import annotations

import argparse
import csv
import datetime
import glob
import hashlib
import io
import json
import os
import re
import zipfile
from collections import Counter, defaultdict
from pathlib import Path

import pyarrow.parquet as pq
import zstandard as zstd
from opencc import OpenCC

# Regexes for cleaning web/markdown/social artifacts
RE_URL = re.compile(r"https?://\S+|www\.\S+")
RE_MD_CODE = re.compile(r"```.*?```", re.DOTALL)
RE_MD_INLINE_CODE = re.compile(r"`[^`]{1,120}`")
RE_MD_IMG = re.compile(r"!\[[^\]]*\]\([^)]*\)")
RE_MD_LINK = re.compile(r"\[([^\]]{1,80})\]\([^)]*\)")
RE_HTML_TAG = re.compile(r"<[^>]{1,120}>")
RE_XHS_EMOJI = re.compile(r"\[[^\]]{1,10}[Rr]\]")
RE_XHS_TOPIC = re.compile(r"#[^#\n]{1,30}(?:\[话题\]#?|#)")
RE_MENTION = re.compile(r"@[\w\u4e00-\u9fff\-_.]{1,24}")
RE_TIEBA_UI = re.compile(
    r"我也说一句(?:还有\d*条回复)?|还有\d+条回复|点击查看(?:全部)?|收起回复|"
    r"来自(?:Android|iPhone|iOS|手机|网页)?客户端|贴吧用户[_A-Za-z0-9]*|"
    r"回复\s*[\w\u4e00-\u9fff\-_.]{1,20}\s*[:：]"
)
RE_WIKI_STUB = re.compile(
    r"的一个市镇|的一个街区|的一个村|的一个社区|邮政编码|INSEE编码|"
    r"位于法国|位于意大利|位于西班牙|位于德国|位于美国[^。\n]{0,20}县|"
    r"是[^。\n]{1,20}科[^。\n]{1,20}属的|小行星|巡天系统|绕太阳运转|轨道倾角|的一座火车站|"
    r"的居民点|的自治市镇|的镇区|的市镇"
)
RE_CJK_RUN = re.compile(r"[\u4e00-\u9fff]+")
RE_SENT_SPLIT = re.compile(r"[。！？；!?\n\r]+")

SPAM_KEYWORDS = (
    "购物礼金",
    "优惠礼包",
    "京东首页搜",
    "淘宝搜",
    "加微信",
    "私信领",
    "扫码领",
    "点我头像",
    "点击下方链接",
    "复制这条信息",
    "打开淘宝",
    "领券下单",
    "关注公众号",
    "免费领取资料",
)

WIKI_CUTOFF_HEADINGS = ("\n参考文献\n", "\n外部链接\n", "\n参见\n", "\n参考资料\n", "\n外部连结\n", "\n參考文獻\n", "\n外部連結\n")


def is_spam(text: str) -> bool:
    for kw in SPAM_KEYWORDS:
        if kw in text:
            return True
    return False


def clean_raw_text(text: str, cc: OpenCC | None = None) -> str:
    if not text:
        return ""
    text = RE_MD_CODE.sub(" ", text)
    text = RE_MD_IMG.sub(" ", text)
    text = RE_MD_LINK.sub(r"\1", text)
    text = RE_URL.sub(" ", text)
    text = RE_HTML_TAG.sub(" ", text)
    text = RE_MD_INLINE_CODE.sub(" ", text)
    text = RE_XHS_EMOJI.sub(" ", text)
    text = RE_XHS_TOPIC.sub(" ", text)
    text = RE_MENTION.sub(" ", text)
    text = RE_TIEBA_UI.sub(" ", text)
    if cc is not None:
        text = cc.convert(text)
    return text


def doc_split(doc_key: str) -> str:
    """Deterministic split: 96% train, 2% val, 2% test."""
    h = int.from_bytes(hashlib.blake2b(doc_key.encode("utf-8"), digest_size=4).digest(), "little") % 100
    if h < 96:
        return "train"
    if h < 98:
        return "val"
    return "test"


def extract_cjk_runs(text: str) -> list[str]:
    runs = []
    for m in RE_CJK_RUN.finditer(text):
        s = m.group(0)
        if len(s) >= 2:
            runs.append(s)
    return runs


def extract_eval_sentences(text: str, max_per_doc: int = 2) -> list[str]:
    """Extract clean natural Chinese sentences (10..42 CJK chars) for typo eval."""
    out = []
    for seg in RE_SENT_SPLIT.split(text):
        seg = seg.strip()
        if not seg or is_spam(seg):
            continue
        # Keep only CJK + common Chinese comma/pause
        cjk_only = "".join(RE_CJK_RUN.findall(seg))
        if 10 <= len(cjk_only) <= 42 and len(cjk_only) / max(len(seg), 1) >= 0.72:
            # Avoid repetitive character spam like "哈哈哈哈哈哈哈"
            if len(set(cjk_only)) >= max(6, len(cjk_only) // 3):
                out.append(cjk_only)
                if len(out) >= max_per_doc:
                    break
    return out


class CorpusWriter:
    def __init__(self, out_dir: Path, max_eval_per_domain: int = 600):
        self.out_dir = out_dir
        (out_dir / "clean").mkdir(parents=True, exist_ok=True)
        (out_dir / "eval").mkdir(parents=True, exist_ok=True)
        self.train_files = {
            "formal": open(out_dir / "clean" / "formal_train.txt", "w", encoding="utf-8"),
            "community": open(out_dir / "clean" / "community_train.txt", "w", encoding="utf-8"),
            "social": open(out_dir / "clean" / "social_train.txt", "w", encoding="utf-8"),
        }
        self.val_sents: dict[str, list[str]] = defaultdict(list)
        self.test_sents: dict[str, list[str]] = defaultdict(list)
        self.max_eval = max_eval_per_domain
        self.seen_hashes: set[bytes] = set()
        self.stats: dict[str, Counter] = defaultdict(Counter)

    def add_doc(self, domain: str, group: str, doc_id: str, cleaned_text: str) -> int:
        if not cleaned_text or is_spam(cleaned_text):
            return 0
        runs = extract_cjk_runs(cleaned_text)
        if not runs:
            return 0
        total_cjk = sum(len(r) for r in runs)
        if total_cjk < 4:
            return 0

        # Exact-content dedup on CJK skeleton (prefix up to 512 chars + total len)
        skeleton = "".join(runs)
        sig_str = f"{len(skeleton)}:{skeleton[:512]}"
        sig = hashlib.blake2b(sig_str.encode("utf-8"), digest_size=12).digest()
        if sig in self.seen_hashes:
            self.stats[domain]["dedup_skipped"] += 1
            return 0
        self.seen_hashes.add(sig)

        split = doc_split(f"{domain}:{doc_id}")
        self.stats[domain][f"{split}_docs"] += 1
        self.stats[domain][f"{split}_chars"] += total_cjk

        if split == "train":
            f = self.train_files[group]
            for r in runs:
                f.write(r)
                f.write("\n")
            return total_cjk
        elif split == "val":
            if len(self.val_sents[domain]) < self.max_eval:
                for s in extract_eval_sentences(cleaned_text, max_per_doc=2):
                    if len(self.val_sents[domain]) < self.max_eval:
                        self.val_sents[domain].append(s)
        else:
            if len(self.test_sents[domain]) < self.max_eval:
                for s in extract_eval_sentences(cleaned_text, max_per_doc=2):
                    if len(self.test_sents[domain]) < self.max_eval:
                        self.test_sents[domain].append(s)
        return 0

    def close(self):
        for f in self.train_files.values():
            f.close()
        with open(self.out_dir / "eval" / "val_sentences.tsv", "w", encoding="utf-8") as vf:
            for dom, sents in sorted(self.val_sents.items()):
                for s in sents:
                    vf.write(f"{dom}\t{s}\n")
        with open(self.out_dir / "eval" / "test_sentences.tsv", "w", encoding="utf-8") as tf:
            for dom, sents in sorted(self.test_sents.items()):
                for s in sents:
                    tf.write(f"{dom}\t{s}\n")
        summary = {dom: dict(cnt) for dom, cnt in sorted(self.stats.items())}
        with open(self.out_dir / "corpus_stats.json", "w", encoding="utf-8") as sf:
            json.dump(summary, sf, ensure_ascii=False, indent=2)
        return summary


def process_zhwiki(raw_dir: Path, writer: CorpusWriter, cc: OpenCC, target_chars: int):
    pq_path = raw_dir / "zhwiki_00002.parquet"
    if not pq_path.exists():
        print("[zhwiki] skipped (not found)")
        return
    pf = pq.ParquetFile(pq_path)
    collected = 0
    for rg in range(pf.num_row_groups):
        table = pf.read_row_group(rg, columns=["id", "title", "text"])
        ids = table["id"].to_pylist()
        titles = table["title"].to_pylist()
        texts = table["text"].to_pylist()
        for doc_id, title, body in zip(ids, titles, texts):
            if not body or len(body) < 500:
                continue
            for cut in WIKI_CUTOFF_HEADINGS:
                idx = body.find(cut)
                if idx != -1:
                    body = body[:idx]
            if len(body) < 400:
                continue
            combined = f"{title or ''}\n{body}"
            cleaned = clean_raw_text(combined, cc=cc)
            if RE_WIKI_STUB.search(cleaned[:320]):
                continue
            collected += writer.add_doc("zhwiki", "formal", str(doc_id), cleaned)
            if collected >= target_chars:
                print(f"[zhwiki] reached target {collected:,} train CJK chars")
                return
    print(f"[zhwiki] finished with {collected:,} train CJK chars")


def process_zhihu_qa(raw_dir: Path, writer: CorpusWriter, cc: OpenCC, target_chars: int, min_year: int = 2025):
    shards = sorted(glob.glob(str(raw_dir / "zhihu_part*.jsonl.zst")))
    if not shards:
        print("[zhihu_qa] skipped (not found)")
        return
    min_ts = int(datetime.datetime(min_year, 1, 1, tzinfo=datetime.timezone.utc).timestamp())
    collected = 0
    for shard_path in shards:
        print(f"[zhihu_qa] scanning {os.path.basename(shard_path)} (year >= {min_year})...")
        with open(shard_path, "rb") as f:
            dctx = zstd.ZstdDecompressor()
            with dctx.stream_reader(f) as reader:
                text_stream = io.TextIOWrapper(reader, encoding="utf-8", errors="ignore")
                for line in text_stream:
                    try:
                        obj = json.loads(line)
                    except Exception:
                        continue
                    ts = obj.get("created_time", 0) or 0
                    if ts < min_ts:
                        continue
                    title = obj.get("question_title") or ""
                    if title == "untitled":
                        title = ""
                    content = obj.get("content") or ""
                    doc_id = str(obj.get("id") or "")
                    cleaned = clean_raw_text(f"{title}\n{content}", cc=cc)
                    collected += writer.add_doc("zhihu_qa_2526", "community", doc_id, cleaned)
                    if collected >= target_chars:
                        print(f"[zhihu_qa] reached target {collected:,} train CJK chars")
                        return
    print(f"[zhihu_qa] finished with {collected:,} train CJK chars")


def process_zhihu_16k(raw_dir: Path, writer: CorpusWriter, cc: OpenCC, target_chars: int):
    zp = raw_dir / "zhihu_16k.zip"
    if not zp.exists():
        print("[zhihu_16k] skipped (not found)")
        return
    collected = 0
    with zipfile.ZipFile(zp) as zf:
        for name in zf.namelist():
            if "/text/" not in name or not name.endswith(".txt"):
                continue
            raw = zf.read(name).decode("utf-8", errors="ignore")
            cleaned = clean_raw_text(raw, cc=cc)
            collected += writer.add_doc("zhihu_16k", "community", name, cleaned)
            if collected >= target_chars:
                print(f"[zhihu_16k] reached target {collected:,} train CJK chars")
                return
    print(f"[zhihu_16k] finished with {collected:,} train CJK chars")


def process_tieba(raw_dir: Path, writer: CorpusWriter, cc: OpenCC):
    files = sorted(glob.glob(str(raw_dir / "tieba" / "*.json")))
    if not files:
        print("[tieba] skipped (not found)")
        return
    collected = 0
    for fp in files:
        try:
            posts = json.load(open(fp, "r", encoding="utf-8", errors="ignore"))
        except Exception:
            continue
        if not isinstance(posts, list):
            continue
        for idx, post in enumerate(posts):
            if not isinstance(post, dict):
                continue
            pid = str(post.get("链接") or f"{os.path.basename(fp)}_{idx}")
            parts = []
            if post.get("标题"):
                parts.append(str(post["标题"]))
            if post.get("楼主内容"):
                parts.append(str(post["楼主内容"]))
            replies = post.get("回复列表")
            if isinstance(replies, list):
                for r in replies:
                    if isinstance(r, str) and r.strip():
                        parts.append(r)
            elif isinstance(replies, str) and replies.strip():
                parts.append(replies)
            # Clean post + each reply separately so spam replies are dropped without losing the thread
            clean_parts = []
            for p in parts:
                if is_spam(p):
                    continue
                cp = clean_raw_text(p, cc=cc)
                if cp:
                    clean_parts.append(cp)
            if clean_parts:
                collected += writer.add_doc("tieba_2025", "social", pid, "\n".join(clean_parts))
    print(f"[tieba] finished with {collected:,} train CJK chars")


def process_rednote_notes(raw_dir: Path, writer: CorpusWriter, cc: OpenCC):
    csv_path = raw_dir / "rednote_notes.csv"
    if not csv_path.exists():
        print("[xhs_notes] skipped (not found)")
        return
    collected = 0
    with open(csv_path, "r", encoding="utf-8-sig", errors="ignore") as f:
        reader = csv.DictReader(f)
        for idx, row in enumerate(reader):
            nid = row.get("note_id") or str(idx)
            title = row.get("title") or ""
            body = row.get("post_text") or ""
            cleaned = clean_raw_text(f"{title}\n{body}", cc=cc)
            collected += writer.add_doc("xhs_notes", "social", nid, cleaned)
    print(f"[xhs_notes] finished with {collected:,} train CJK chars")


def process_xhs_comments(raw_dir: Path, writer: CorpusWriter, cc: OpenCC):
    csv_path = raw_dir / "xhs_comments.csv"
    if not csv_path.exists():
        print("[xhs_comments] skipped (not found)")
        return
    collected = 0
    seen_ids: set[str] = set()
    with open(csv_path, "r", encoding="utf-8-sig", errors="ignore") as f:
        reader = csv.DictReader(f)
        for idx, row in enumerate(reader):
            cid = (row.get("评论ID") or "").strip()
            if cid:
                if cid in seen_ids:
                    continue
                seen_ids.add(cid)
            else:
                cid = str(idx)
            content = (row.get("评论内容") or "").strip()
            if not content:
                continue
            cleaned = clean_raw_text(content, cc=cc)
            collected += writer.add_doc("xhs_comments_2025", "social", cid, cleaned)
    print(f"[xhs_comments] finished with {collected:,} train CJK chars")


def process_extra_social(raw_dir: Path, writer: CorpusWriter, cc: OpenCC):
    files = sorted(glob.glob(str(raw_dir / "extra_social" / "*.txt")))
    if not files:
        return
    collected = 0
    for fp in files:
        base = os.path.basename(fp)
        with open(fp, "r", encoding="utf-8", errors="ignore") as f:
            for idx, line in enumerate(f):
                cleaned = clean_raw_text(line.strip(), cc=cc)
                if cleaned:
                    collected += writer.add_doc("extra_social", "social", f"{base}:{idx}", cleaned)
    print(f"[extra_social] finished with {collected:,} train CJK chars")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw-dir", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--wiki-chars", type=int, default=20_000_000)
    ap.add_argument("--zhihu-qa-chars", type=int, default=16_000_000)
    ap.add_argument("--zhihu-16k-chars", type=int, default=6_000_000)
    args = ap.parse_args()

    raw_dir = Path(args.raw_dir)
    out_dir = Path(args.out_dir)
    cc = OpenCC("t2s")
    writer = CorpusWriter(out_dir)

    process_zhwiki(raw_dir, writer, cc, target_chars=args.wiki_chars)
    process_zhihu_qa(raw_dir, writer, cc, target_chars=args.zhihu_qa_chars, min_year=2025)
    process_zhihu_16k(raw_dir, writer, cc, target_chars=args.zhihu_16k_chars)
    process_tieba(raw_dir, writer, cc)
    process_rednote_notes(raw_dir, writer, cc)
    process_xhs_comments(raw_dir, writer, cc)
    process_extra_social(raw_dir, writer, cc)

    summary = writer.close()
    print("\n=== Corpus Summary ===")
    total_train = 0
    for dom, st in summary.items():
        tc = st.get("train_chars", 0)
        total_train += tc
        print(
            f"  {dom:20s}: train={tc/1e6:6.2f}M chars ({st.get('train_docs', 0):6d} docs), "
            f"val_docs={st.get('val_docs', 0):4d}, test_docs={st.get('test_docs', 0):4d}, "
            f"dedup_skip={st.get('dedup_skipped', 0)}"
        )
    print(f"  TOTAL TRAIN CJK CHARS: {total_train/1e6:.2f}M")


if __name__ == "__main__":
    main()
