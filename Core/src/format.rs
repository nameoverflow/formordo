use crate::code::{compose_phrase_code, PackedCode, PackedPinyin, Stem2};
use crate::mmap_buf::ByteSource;
use std::io;
use std::path::Path;

pub const WBDICT_MAGIC: &[u8; 8] = b"WBDICT01";
pub const WBAUX_MAGIC: &[u8; 8] = b"WBAUX001";

pub const ENTRY_FLAG_SINGLE_CHAR: u16 = 1 << 0;
pub const ENTRY_FLAG_EXT_RARE: u16 = 1 << 1;
pub const ENTRY_FLAG_SYMBOL: u16 = 1 << 2;

const HEADER_LEN: usize = 64;
const BUCKET_STRIDE: usize = 12; // packed_code: u32, start: u32, count: u16, reserved: u16
const ENTRY_STRIDE: usize = 12;  // str_off: u32, weight: u32, str_len: u16, flags: u16
const CHAR_STRIDE: usize = 20;   // cp: u32, stem2: u16, flags: u16, shortest: u32, primary_short: u32, full: u32

#[derive(Clone, Copy, Debug)]
pub struct DictEntryRef<'a> {
    pub text: &'a str,
    pub weight: u32,
    pub flags: u16,
    pub code: PackedCode,
}

impl<'a> DictEntryRef<'a> {
    #[inline]
    pub fn is_single_char(&self) -> bool {
        (self.flags & ENTRY_FLAG_SINGLE_CHAR) != 0
    }
    #[inline]
    pub fn is_ext_rare(&self) -> bool {
        (self.flags & ENTRY_FLAG_EXT_RARE) != 0
    }
}

#[derive(Clone, Copy, Debug, Default)]
pub struct CharMeta {
    pub codepoint: u32,
    pub stem2: Stem2,
    pub flags: u16,
    pub shortest_code: PackedCode,
    /// Non-empty only when this character is the #1 primary candidate at `primary_short_code`.
    pub primary_short_code: PackedCode,
    pub full_code: PackedCode,
}

pub struct DictBuildInput {
    pub schema_id: u32,
    pub entries: Vec<(PackedCode, String, u32, u16)>,
    pub char_metas: Vec<CharMeta>,
}

#[inline]
fn read_u16(b: &[u8], off: usize) -> u16 {
    u16::from_le_bytes([b[off], b[off + 1]])
}

#[inline]
fn read_u32(b: &[u8], off: usize) -> u32 {
    u32::from_le_bytes([b[off], b[off + 1], b[off + 2], b[off + 3]])
}

#[inline]
fn read_u64(b: &[u8], off: usize) -> u64 {
    u64::from_le_bytes([
        b[off],
        b[off + 1],
        b[off + 2],
        b[off + 3],
        b[off + 4],
        b[off + 5],
        b[off + 6],
        b[off + 7],
    ])
}

pub fn serialize_wbdict(mut input: DictBuildInput) -> Vec<u8> {
    // Sort entries by (packed_code ASC, is_ext_rare ASC, weight DESC, text_char_len ASC, text ASC)
    input.entries.sort_by(|a, b| {
        a.0.cmp(&b.0)
            .then_with(|| {
                let ra = (a.3 & ENTRY_FLAG_EXT_RARE) != 0;
                let rb = (b.3 & ENTRY_FLAG_EXT_RARE) != 0;
                ra.cmp(&rb)
            })
            .then_with(|| b.2.cmp(&a.2))
            .then_with(|| a.1.chars().count().cmp(&b.1.chars().count()))
            .then_with(|| a.1.cmp(&b.1))
    });
    // Deduplicate identical (code, text) keeping first (highest weight)
    let mut deduped: Vec<(PackedCode, String, u32, u16)> = Vec::with_capacity(input.entries.len());
    for item in input.entries {
        if let Some(last) = deduped.last() {
            if last.0 == item.0 && last.1 == item.1 {
                continue;
            }
        }
        deduped.push(item);
    }

    input.char_metas.sort_by_key(|m| m.codepoint);
    input.char_metas.dedup_by_key(|m| m.codepoint);

    // Compute primary_short_code accurately from sorted buckets!
    let mut primary_short_by_cp = std::collections::HashMap::<u32, PackedCode>::new();
    {
        let mut i = 0;
        while i < deduped.len() {
            let code = deduped[i].0;
            let code_len = code.len();
            if code_len < 4 {
                // First non-rare entry in this bucket is #1 primary candidate at `code`
                let first = &deduped[i];
                if (first.3 & ENTRY_FLAG_SINGLE_CHAR) != 0
                    && (first.3 & ENTRY_FLAG_EXT_RARE) == 0
                {
                    if let Some(ch) = first.1.chars().next() {
                        let cp = ch as u32;
                        primary_short_by_cp
                            .entry(cp)
                            .and_modify(|prev| {
                                if code.len() < prev.len() {
                                    *prev = code;
                                }
                            })
                            .or_insert(code);
                    }
                }
            }
            while i < deduped.len() && deduped[i].0 == code {
                i += 1;
            }
        }
    }
    for m in &mut input.char_metas {
        if let Some(&psc) = primary_short_by_cp.get(&m.codepoint) {
            if psc.len() < m.full_code.len() {
                m.primary_short_code = psc;
            }
        }
    }

    // Build string pool (deduplicated strings)
    let mut str_offsets = std::collections::HashMap::<String, (u32, u16)>::new();
    let mut string_pool = Vec::<u8>::new();
    for (_, text, _, _) in &deduped {
        if !str_offsets.contains_key(text) {
            let off = string_pool.len() as u32;
            let bytes = text.as_bytes();
            let len = bytes.len().min(u16::MAX as usize) as u16;
            string_pool.extend_from_slice(&bytes[..len as usize]);
            str_offsets.insert(text.clone(), (off, len));
        }
    }

    // Build buckets + entry table
    let mut buckets_buf = Vec::<u8>::new();
    let mut entries_buf = Vec::<u8>::with_capacity(deduped.len() * ENTRY_STRIDE);
    let mut bucket_count = 0u32;

    let mut idx = 0usize;
    while idx < deduped.len() {
        let code = deduped[idx].0;
        let start = idx as u32;
        let mut end = idx;
        while end < deduped.len() && deduped[end].0 == code {
            let (_, ref text, weight, flags) = deduped[end];
            let (str_off, str_len) = str_offsets[text];
            entries_buf.extend_from_slice(&str_off.to_le_bytes());
            entries_buf.extend_from_slice(&weight.to_le_bytes());
            entries_buf.extend_from_slice(&str_len.to_le_bytes());
            entries_buf.extend_from_slice(&flags.to_le_bytes());
            end += 1;
        }
        let count = (end - idx).min(u16::MAX as usize) as u16;
        buckets_buf.extend_from_slice(&code.0.to_le_bytes());
        buckets_buf.extend_from_slice(&start.to_le_bytes());
        buckets_buf.extend_from_slice(&count.to_le_bytes());
        buckets_buf.extend_from_slice(&0u16.to_le_bytes());
        bucket_count += 1;
        idx = end;
    }

    let mut chars_buf = Vec::<u8>::with_capacity(input.char_metas.len() * CHAR_STRIDE);
    for m in &input.char_metas {
        chars_buf.extend_from_slice(&m.codepoint.to_le_bytes());
        chars_buf.extend_from_slice(&m.stem2.0.to_le_bytes());
        chars_buf.extend_from_slice(&m.flags.to_le_bytes());
        chars_buf.extend_from_slice(&m.shortest_code.0.to_le_bytes());
        chars_buf.extend_from_slice(&m.primary_short_code.0.to_le_bytes());
        chars_buf.extend_from_slice(&m.full_code.0.to_le_bytes());
    }

    let buckets_off = HEADER_LEN as u32;
    let entries_off = buckets_off + buckets_buf.len() as u32;
    let chars_off = entries_off + entries_buf.len() as u32;
    let strings_off = chars_off + chars_buf.len() as u32;
    let total_len = strings_off as usize + string_pool.len();

    let mut out = Vec::<u8>::with_capacity(total_len);
    out.extend_from_slice(WBDICT_MAGIC);
    out.extend_from_slice(&input.schema_id.to_le_bytes());
    out.extend_from_slice(&bucket_count.to_le_bytes());
    out.extend_from_slice(&(deduped.len() as u32).to_le_bytes());
    out.extend_from_slice(&(input.char_metas.len() as u32).to_le_bytes());
    out.extend_from_slice(&buckets_off.to_le_bytes());
    out.extend_from_slice(&entries_off.to_le_bytes());
    out.extend_from_slice(&chars_off.to_le_bytes());
    out.extend_from_slice(&strings_off.to_le_bytes());
    out.extend_from_slice(&(string_pool.len() as u32).to_le_bytes());
    while out.len() < HEADER_LEN {
        out.push(0);
    }
    out.extend_from_slice(&buckets_buf);
    out.extend_from_slice(&entries_buf);
    out.extend_from_slice(&chars_buf);
    out.extend_from_slice(&string_pool);
    out
}

/// Zero-copy view over a `.wbdict` binary image.
pub struct DictView {
    buf: ByteSource,
    pub schema_id: u32,
    bucket_count: usize,
    entry_count: usize,
    char_count: usize,
    buckets_off: usize,
    entries_off: usize,
    chars_off: usize,
    strings_off: usize,
    strings_len: usize,
}

impl DictView {
    pub fn open_mmap<P: AsRef<Path>>(path: P) -> io::Result<Self> {
        let src = ByteSource::mmap_file(path)?;
        Self::from_source(src)
    }

    pub fn from_bytes(bytes: Vec<u8>) -> io::Result<Self> {
        Self::from_source(ByteSource::from_vec(bytes))
    }

    pub fn from_source(buf: ByteSource) -> io::Result<Self> {
        let b = buf.as_slice();
        if b.len() < HEADER_LEN || &b[0..8] != WBDICT_MAGIC {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "invalid WBDICT header",
            ));
        }
        let schema_id = read_u32(b, 8);
        let bucket_count = read_u32(b, 12) as usize;
        let entry_count = read_u32(b, 16) as usize;
        let char_count = read_u32(b, 20) as usize;
        let buckets_off = read_u32(b, 24) as usize;
        let entries_off = read_u32(b, 28) as usize;
        let chars_off = read_u32(b, 32) as usize;
        let strings_off = read_u32(b, 36) as usize;
        let strings_len = read_u32(b, 40) as usize;

        if buckets_off + bucket_count * BUCKET_STRIDE > b.len()
            || entries_off + entry_count * ENTRY_STRIDE > b.len()
            || chars_off + char_count * CHAR_STRIDE > b.len()
            || strings_off + strings_len > b.len()
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "truncated WBDICT section",
            ));
        }

        Ok(Self {
            buf,
            schema_id,
            bucket_count,
            entry_count,
            char_count,
            buckets_off,
            entries_off,
            chars_off,
            strings_off,
            strings_len,
        })
    }

    #[inline]
    fn bucket_at(&self, i: usize) -> (PackedCode, usize, usize) {
        let b = self.buf.as_slice();
        let off = self.buckets_off + i * BUCKET_STRIDE;
        let code = PackedCode(read_u32(b, off));
        let start = read_u32(b, off + 4) as usize;
        let count = read_u16(b, off + 8) as usize;
        (code, start, count)
    }

    #[inline]
    fn entry_at(&self, idx: usize, code: PackedCode) -> Option<DictEntryRef<'_>> {
        if idx >= self.entry_count {
            return None;
        }
        let b = self.buf.as_slice();
        let off = self.entries_off + idx * ENTRY_STRIDE;
        let str_off = read_u32(b, off) as usize;
        let weight = read_u32(b, off + 4);
        let str_len = read_u16(b, off + 8) as usize;
        let flags = read_u16(b, off + 10);
        if str_off + str_len > self.strings_len {
            return None;
        }
        let s_start = self.strings_off + str_off;
        let text = core::str::from_utf8(&b[s_start..s_start + str_len]).ok()?;
        Some(DictEntryRef {
            text,
            weight,
            flags,
            code,
        })
    }

    fn lower_bound_bucket(&self, target: PackedCode) -> usize {
        let mut lo = 0usize;
        let mut hi = self.bucket_count;
        while lo < hi {
            let mid = lo + (hi - lo) / 2;
            let (c, _, _) = self.bucket_at(mid);
            if c < target {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        lo
    }

    pub fn lookup_exact(&self, code: PackedCode, include_rare: bool) -> Vec<DictEntryRef<'_>> {
        let idx = self.lower_bound_bucket(code);
        if idx >= self.bucket_count {
            return Vec::new();
        }
        let (c, start, count) = self.bucket_at(idx);
        if c != code {
            return Vec::new();
        }
        let mut out = Vec::with_capacity(count);
        for i in start..start + count {
            if let Some(e) = self.entry_at(i, code) {
                if !include_rare && e.is_ext_rare() {
                    continue;
                }
                out.push(e);
            }
        }
        out
    }

    pub fn has_exact(&self, code: PackedCode, include_rare: bool) -> bool {
        let idx = self.lower_bound_bucket(code);
        if idx >= self.bucket_count {
            return false;
        }
        let (c, start, count) = self.bucket_at(idx);
        if c != code {
            return false;
        }
        if include_rare {
            return count > 0;
        }
        for i in start..start + count {
            if let Some(e) = self.entry_at(i, code) {
                if !e.is_ext_rare() {
                    return true;
                }
            }
        }
        false
    }

    /// Prefix completion lookup for codes strictly longer than `prefix`.
    pub fn lookup_longer_prefix(
        &self,
        prefix: PackedCode,
        limit: usize,
        include_rare: bool,
    ) -> Vec<DictEntryRef<'_>> {
        let (lo_code, hi_code) = prefix.prefix_range();
        let mut b_idx = self.lower_bound_bucket(lo_code);
        let mut collected = Vec::new();
        while b_idx < self.bucket_count {
            let (c, start, count) = self.bucket_at(b_idx);
            if c > hi_code {
                break;
            }
            if c != prefix {
                for i in start..start + count {
                    if let Some(e) = self.entry_at(i, c) {
                        if !include_rare && e.is_ext_rare() {
                            continue;
                        }
                        collected.push(e);
                        // Gather enough high-weight entries then sort
                        if collected.len() >= limit * 8 {
                            break;
                        }
                    }
                }
            }
            if collected.len() >= limit * 8 {
                break;
            }
            b_idx += 1;
        }
        collected.sort_by(|a, b| {
            a.code
                .len()
                .cmp(&b.code.len())
                .then_with(|| b.weight.cmp(&a.weight))
        });
        collected.truncate(limit);
        collected
    }

    pub fn char_meta(&self, ch: char) -> Option<CharMeta> {
        let target = ch as u32;
        let b = self.buf.as_slice();
        let mut lo = 0usize;
        let mut hi = self.char_count;
        while lo < hi {
            let mid = lo + (hi - lo) / 2;
            let off = self.chars_off + mid * CHAR_STRIDE;
            let cp = read_u32(b, off);
            if cp < target {
                lo = mid + 1;
            } else if cp > target {
                hi = mid;
            } else {
                return Some(CharMeta {
                    codepoint: cp,
                    stem2: Stem2(read_u16(b, off + 4)),
                    flags: read_u16(b, off + 6),
                    shortest_code: PackedCode(read_u32(b, off + 8)),
                    primary_short_code: PackedCode(read_u32(b, off + 12)),
                    full_code: PackedCode(read_u32(b, off + 16)),
                });
            }
        }
        None
    }

    /// Dynamically compute the 4-letter Wubi code for any Chinese phrase (2+ chars)
    /// under this schema (`86` / `98` / `06`), enabling cross-schema user phrases!
    pub fn encode_phrase(&self, text: &str) -> Option<PackedCode> {
        let mut stems = Vec::with_capacity(4);
        for ch in text.chars() {
            let meta = self.char_meta(ch)?;
            if !meta.stem2.is_valid() {
                return None;
            }
            stems.push(meta.stem2);
        }
        compose_phrase_code(&stems)
    }

    pub fn stats(&self) -> (usize, usize, usize) {
        (self.bucket_count, self.entry_count, self.char_count)
    }
}

// ============================================================================
// Shared Auxiliary Index (.wbaux): Pinyin Reverse Lookup + Quantized Bigram LM
// ============================================================================

const AUX_HEADER_LEN: usize = 48;
const PY_BUCKET_STRIDE: usize = 12; // py_packed: u32, start: u32, count: u16, pad: u16
const PY_ITEM_STRIDE: usize = 12;   // cp: u32, weight: u32, py_str_off: u16, py_str_len: u16
const BIGRAM_STRIDE: usize = 10;    // pair_key: u64, log_boost_q8: u16

pub struct AuxBuildInput {
    /// `(pinyin_ascii, pinyin_display, codepoint, weight)`
    pub pinyin_items: Vec<(PackedPinyin, String, u32, u32)>,
    /// `(((prev_cp as u64) << 32) | (next_cp as u64), log_boost_q8)`
    pub bigrams: Vec<(u64, u16)>,
}

pub fn serialize_wbaux(mut input: AuxBuildInput) -> Vec<u8> {
    input
        .pinyin_items
        .sort_by(|a, b| a.0.cmp(&b.0).then_with(|| b.3.cmp(&a.3)).then_with(|| a.2.cmp(&b.2)));
    input.pinyin_items.dedup_by(|a, b| a.0 == b.0 && a.2 == b.2);

    input.bigrams.sort_by_key(|x| x.0);
    input.bigrams.dedup_by_key(|x| x.0);

    let mut py_str_map = std::collections::HashMap::<String, (u16, u16)>::new();
    let mut py_pool = Vec::<u8>::new();
    for (_, disp, _, _) in &input.pinyin_items {
        if !py_str_map.contains_key(disp) && py_pool.len() + disp.len() < u16::MAX as usize {
            let off = py_pool.len() as u16;
            let len = disp.len() as u16;
            py_pool.extend_from_slice(disp.as_bytes());
            py_str_map.insert(disp.clone(), (off, len));
        }
    }

    let mut py_buckets = Vec::<u8>::new();
    let mut py_items = Vec::<u8>::with_capacity(input.pinyin_items.len() * PY_ITEM_STRIDE);
    let mut py_bucket_count = 0u32;

    let mut idx = 0usize;
    while idx < input.pinyin_items.len() {
        let py = input.pinyin_items[idx].0;
        let start = idx as u32;
        let mut end = idx;
        while end < input.pinyin_items.len() && input.pinyin_items[end].0 == py {
            let (_, ref disp, cp, wt) = input.pinyin_items[end];
            let (so, sl) = py_str_map.get(disp).copied().unwrap_or((0, 0));
            py_items.extend_from_slice(&cp.to_le_bytes());
            py_items.extend_from_slice(&wt.to_le_bytes());
            py_items.extend_from_slice(&so.to_le_bytes());
            py_items.extend_from_slice(&sl.to_le_bytes());
            end += 1;
        }
        let count = (end - idx).min(u16::MAX as usize) as u16;
        py_buckets.extend_from_slice(&py.0.to_le_bytes());
        py_buckets.extend_from_slice(&start.to_le_bytes());
        py_buckets.extend_from_slice(&count.to_le_bytes());
        py_buckets.extend_from_slice(&0u16.to_le_bytes());
        py_bucket_count += 1;
        idx = end;
    }

    let mut bg_buf = Vec::<u8>::with_capacity(input.bigrams.len() * BIGRAM_STRIDE);
    for (pair, boost) in &input.bigrams {
        bg_buf.extend_from_slice(&pair.to_le_bytes());
        bg_buf.extend_from_slice(&boost.to_le_bytes());
    }

    let py_buckets_off = AUX_HEADER_LEN as u32;
    let py_items_off = py_buckets_off + py_buckets.len() as u32;
    let bg_off = py_items_off + py_items.len() as u32;
    let pool_off = bg_off + bg_buf.len() as u32;

    let mut out = Vec::<u8>::with_capacity(pool_off as usize + py_pool.len());
    out.extend_from_slice(WBAUX_MAGIC);
    out.extend_from_slice(&py_bucket_count.to_le_bytes());
    out.extend_from_slice(&(input.pinyin_items.len() as u32).to_le_bytes());
    out.extend_from_slice(&(input.bigrams.len() as u32).to_le_bytes());
    out.extend_from_slice(&py_buckets_off.to_le_bytes());
    out.extend_from_slice(&py_items_off.to_le_bytes());
    out.extend_from_slice(&bg_off.to_le_bytes());
    out.extend_from_slice(&pool_off.to_le_bytes());
    out.extend_from_slice(&(py_pool.len() as u32).to_le_bytes());
    while out.len() < AUX_HEADER_LEN {
        out.push(0);
    }
    out.extend_from_slice(&py_buckets);
    out.extend_from_slice(&py_items);
    out.extend_from_slice(&bg_buf);
    out.extend_from_slice(&py_pool);
    out
}

pub struct AuxView {
    buf: ByteSource,
    py_bucket_count: usize,
    py_item_count: usize,
    bigram_count: usize,
    py_buckets_off: usize,
    py_items_off: usize,
    bg_off: usize,
    pool_off: usize,
    pool_len: usize,
}

impl AuxView {
    pub fn open_mmap<P: AsRef<Path>>(path: P) -> io::Result<Self> {
        Self::from_source(ByteSource::mmap_file(path)?)
    }

    pub fn from_bytes(bytes: Vec<u8>) -> io::Result<Self> {
        Self::from_source(ByteSource::from_vec(bytes))
    }

    pub fn from_source(buf: ByteSource) -> io::Result<Self> {
        let b = buf.as_slice();
        if b.len() < AUX_HEADER_LEN || &b[0..8] != WBAUX_MAGIC {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "invalid WBAUX header",
            ));
        }
        let py_bucket_count = read_u32(b, 8) as usize;
        let py_item_count = read_u32(b, 12) as usize;
        let bigram_count = read_u32(b, 16) as usize;
        let py_buckets_off = read_u32(b, 20) as usize;
        let py_items_off = read_u32(b, 24) as usize;
        let bg_off = read_u32(b, 28) as usize;
        let pool_off = read_u32(b, 32) as usize;
        let pool_len = read_u32(b, 36) as usize;

        if py_buckets_off + py_bucket_count * PY_BUCKET_STRIDE > b.len()
            || py_items_off + py_item_count * PY_ITEM_STRIDE > b.len()
            || bg_off + bigram_count * BIGRAM_STRIDE > b.len()
            || pool_off + pool_len > b.len()
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "truncated WBAUX section",
            ));
        }

        Ok(Self {
            buf,
            py_bucket_count,
            py_item_count,
            bigram_count,
            py_buckets_off,
            py_items_off,
            bg_off,
            pool_off,
            pool_len,
        })
    }

    /// Look up characters by Pinyin prefix (1..=6 ASCII letters), returning `(char, weight, pinyin_str, exact_match)`.
    pub fn lookup_pinyin(&self, query: &[u8], limit: usize) -> Vec<(char, u32, &str, bool)> {
        let Some((lo_py, hi_py)) = PackedPinyin::prefix_range(query) else {
            return Vec::new();
        };
        let b = self.buf.as_slice();
        let mut lo = 0usize;
        let mut hi = self.py_bucket_count;
        while lo < hi {
            let mid = lo + (hi - lo) / 2;
            let py = PackedPinyin(read_u32(b, self.py_buckets_off + mid * PY_BUCKET_STRIDE));
            if py < lo_py {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        let mut results = Vec::new();
        let mut seen = std::collections::HashSet::<u32>::new();
        let mut idx = lo;
        while idx < self.py_bucket_count {
            let boff = self.py_buckets_off + idx * PY_BUCKET_STRIDE;
            let py = PackedPinyin(read_u32(b, boff));
            if py > hi_py {
                break;
            }
            let exact = py == lo_py;
            let start = read_u32(b, boff + 4) as usize;
            let count = read_u16(b, boff + 8) as usize;
            for i in start..(start + count).min(self.py_item_count) {
                let ioff = self.py_items_off + i * PY_ITEM_STRIDE;
                let cp = read_u32(b, ioff);
                if !seen.insert(cp) {
                    continue;
                }
                let wt = read_u32(b, ioff + 4);
                let so = read_u16(b, ioff + 8) as usize;
                let sl = read_u16(b, ioff + 10) as usize;
                let py_str = if so + sl <= self.pool_len {
                    core::str::from_utf8(&b[self.pool_off + so..self.pool_off + so + sl])
                        .unwrap_or("")
                } else {
                    ""
                };
                if let Some(ch) = char::from_u32(cp) {
                    results.push((ch, wt, py_str, exact));
                }
                if results.len() >= limit * 6 {
                    break;
                }
            }
            if results.len() >= limit * 6 {
                break;
            }
            idx += 1;
        }
        results.sort_by(|a, b| b.3.cmp(&a.3).then_with(|| b.1.cmp(&a.1)));
        results.truncate(limit);
        results
    }

    /// Returns corpus transition log-boost (in nats, `0.0 .. ~4.5`) from `prev_char` to `next_char`.
    #[inline]
    pub fn bigram_boost(&self, prev_char: char, next_char: char) -> f32 {
        let key = ((prev_char as u64) << 32) | (next_char as u64);
        let b = self.buf.as_slice();
        let mut lo = 0usize;
        let mut hi = self.bigram_count;
        while lo < hi {
            let mid = lo + (hi - lo) / 2;
            let off = self.bg_off + mid * BIGRAM_STRIDE;
            let k = read_u64(b, off);
            if k < key {
                lo = mid + 1;
            } else if k > key {
                hi = mid;
            } else {
                let q8 = read_u16(b, off + 8);
                return (q8 as f32) / 256.0;
            }
        }
        0.0
    }
}
