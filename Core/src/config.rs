use std::fs;
use std::io;
use std::path::Path;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u32)]
pub enum WubiSchema {
    Wubi86 = 86,
    Wubi98 = 98,
    Wubi06 = 6,
}

impl WubiSchema {
    pub fn from_id(id: u32) -> Self {
        match id {
            98 => Self::Wubi98,
            6 | 2006 => Self::Wubi06,
            _ => Self::Wubi86,
        }
    }

    pub fn from_str_tag(s: &str) -> Self {
        match s.trim().to_ascii_lowercase().as_str() {
            "98" | "wubi98" => Self::Wubi98,
            "06" | "2006" | "wubi06" | "new_century" | "xinshiji" => Self::Wubi06,
            _ => Self::Wubi86,
        }
    }

    pub fn as_tag(self) -> &'static str {
        match self {
            Self::Wubi86 => "86",
            Self::Wubi98 => "98",
            Self::Wubi06 => "06",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::Wubi86 => "86版五笔",
            Self::Wubi98 => "98版五笔",
            Self::Wubi06 => "新世纪五笔",
        }
    }

    pub fn slot_index(self) -> usize {
        match self {
            Self::Wubi86 => 0,
            Self::Wubi98 => 1,
            Self::Wubi06 => 2,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FourthEmptyBehavior {
    /// 阻断无效的第 4 码，保留前 3 码并发出提示（主流五笔默认习惯）
    Block,
    /// 第 4 码空码时自动清空重输
    Clear,
}

impl FourthEmptyBehavior {
    pub fn from_tag(s: &str) -> Self {
        match s.trim().to_ascii_lowercase().as_str() {
            "clear" => Self::Clear,
            _ => Self::Block,
        }
    }
    pub fn as_tag(self) -> &'static str {
        match self {
            Self::Block => "block",
            Self::Clear => "clear",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ShiftToggleMode {
    /// Shift 切换英文时将未上屏编码作为英文直接上屏（苹果原生手感）
    CommitCode,
    /// Shift 切换英文时将当前首选候选词上屏
    CommitFirst,
    /// Shift 切换英文时直接丢弃未上屏编码
    Clear,
}

impl ShiftToggleMode {
    pub fn from_tag(s: &str) -> Self {
        match s.trim().to_ascii_lowercase().as_str() {
            "commit_first" | "first" => Self::CommitFirst,
            "clear" => Self::Clear,
            _ => Self::CommitCode,
        }
    }
    pub fn as_tag(self) -> &'static str {
        match self {
            Self::CommitCode => "commit_code",
            Self::CommitFirst => "commit_first",
            Self::Clear => "clear",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CandidateOrientation {
    Horizontal,
    Vertical,
}

impl CandidateOrientation {
    pub fn from_tag(s: &str) -> Self {
        match s.trim().to_ascii_lowercase().as_str() {
            "vertical" | "vert" => Self::Vertical,
            _ => Self::Horizontal,
        }
    }
    pub fn as_tag(self) -> &'static str {
        match self {
            Self::Horizontal => "horizontal",
            Self::Vertical => "vertical",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct TypoConfig {
    /// 是否开启统计与触控误触纠正
    pub enabled: bool,
    /// 触屏端个人触摸热区动态自适应（EMA 微调每键判定中心）
    pub touch_hitbox_adapt: bool,
    /// 空码救回 / 键边缘滑偏时直接升为首选的后验置信度阈值 (0.50..=0.99)
    pub promote_threshold: f32,
    /// 精确码有效时在次选位展示纠错候选的最低置信度阈值 (0.15..=0.80)
    pub suggest_threshold: f32,
    /// 纠错救回项是否抑制「四码唯一自动上屏」，防止误触把错字自动顶上屏
    pub suppress_auto_commit_on_correction: bool,
}

impl Default for TypoConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            touch_hitbox_adapt: true,
            promote_threshold: 0.82,
            suggest_threshold: 0.30,
            suppress_auto_commit_on_correction: true,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct WubiConfig {
    pub schema: WubiSchema,
    /// 四码唯一自动上屏
    pub fourth_code_auto_commit: bool,
    /// 第五码自动顶字上屏（四码重码时敲第 5 码将首选上屏并开启新一轮首码）
    pub fifth_code_push_commit: bool,
    /// 四码空码处理方式
    pub fourth_empty_behavior: FourthEmptyBehavior,
    /// 最短编码（简码）优先置顶
    pub shortest_code_first: bool,
    /// 出简不出全（有唯一简码的单字在输入全码时后置，培养简码肌肉记忆）
    pub strict_shortcode: bool,
    /// 全码输入时提示存在更短简码（如 ⚡q）
    pub show_shortcode_hint: bool,
    /// 词组动态调频
    pub dynamic_word_freq: bool,
    /// 单字动态调频（默认关闭以固定单字重码序）
    pub dynamic_char_freq: bool,
    /// 连打历史自动组词
    pub auto_phrase: bool,
    /// 连打自动组词触发次数阈值（1 或 2，默认 2 次防噪音成词）
    pub auto_phrase_threshold: u8,
    /// z 键万能通配查询 + 拼音反查 + zz 符号
    pub z_omnipotent: bool,
    /// 分号/引号快捷选 2、3 候选词
    pub semicolon_quote_select: bool,
    /// 中文标点与成对引号智能配对
    pub smart_punctuation: bool,
    /// 扩展生僻大字集开关
    pub enable_rare_charset: bool,
    /// Shift 中英切换策略
    pub shift_toggle_mode: ShiftToggleMode,
    /// 每页候选词个数 (3..=9)
    pub page_size: u8,
    /// 候选栏方向
    pub orientation: CandidateOrientation,
    /// 统计 + 触控热区误触纠正配置
    pub typo: TypoConfig,
}

impl Default for WubiConfig {
    fn default() -> Self {
        Self {
            schema: WubiSchema::Wubi86,
            fourth_code_auto_commit: true,
            fifth_code_push_commit: true,
            fourth_empty_behavior: FourthEmptyBehavior::Block,
            shortest_code_first: true,
            strict_shortcode: false,
            show_shortcode_hint: true,
            dynamic_word_freq: true,
            dynamic_char_freq: false,
            auto_phrase: true,
            auto_phrase_threshold: 2,
            z_omnipotent: true,
            semicolon_quote_select: false,
            smart_punctuation: true,
            enable_rare_charset: false,
            shift_toggle_mode: ShiftToggleMode::CommitCode,
            page_size: 5,
            orientation: CandidateOrientation::Horizontal,
            typo: TypoConfig::default(),
        }
    }
}

impl WubiConfig {
    pub fn to_toml_string(&self) -> String {
        format!(
            concat!(
                "# 棱五笔 (PrisWubi) 配置文件 — macOS 与 iOS 通用内核\n",
                "# 修改保存后将实时生效\n\n",
                "[general]\n",
                "# 五笔版本: \"86\" | \"98\" | \"06\" (新世纪)\n",
                "schema = \"{}\"\n",
                "page_size = {}\n",
                "# 候选栏方向: \"horizontal\" | \"vertical\"\n",
                "orientation = \"{}\"\n",
                "# Shift 切换中英行为: \"commit_code\" | \"commit_first\" | \"clear\"\n",
                "shift_toggle_mode = \"{}\"\n",
                "smart_punctuation = {}\n",
                "semicolon_quote_select = {}\n\n",
                "[typing]\n",
                "fourth_code_auto_commit = {}\n",
                "fifth_code_push_commit = {}\n",
                "# 四码空码行为: \"block\" | \"clear\"\n",
                "fourth_empty_behavior = \"{}\"\n",
                "shortest_code_first = {}\n",
                "strict_shortcode = {}\n",
                "show_shortcode_hint = {}\n",
                "dynamic_word_freq = {}\n",
                "dynamic_char_freq = {}\n",
                "auto_phrase = {}\n",
                "auto_phrase_threshold = {}\n",
                "z_omnipotent = {}\n",
                "enable_rare_charset = {}\n\n",
                "[typo_correction]\n",
                "enabled = {}\n",
                "touch_hitbox_adapt = {}\n",
                "promote_threshold = {:.2}\n",
                "suggest_threshold = {:.2}\n",
                "suppress_auto_commit_on_correction = {}\n"
            ),
            self.schema.as_tag(),
            self.page_size,
            self.orientation.as_tag(),
            self.shift_toggle_mode.as_tag(),
            self.smart_punctuation,
            self.semicolon_quote_select,
            self.fourth_code_auto_commit,
            self.fifth_code_push_commit,
            self.fourth_empty_behavior.as_tag(),
            self.shortest_code_first,
            self.strict_shortcode,
            self.show_shortcode_hint,
            self.dynamic_word_freq,
            self.dynamic_char_freq,
            self.auto_phrase,
            self.auto_phrase_threshold,
            self.z_omnipotent,
            self.enable_rare_charset,
            self.typo.enabled,
            self.typo.touch_hitbox_adapt,
            self.typo.promote_threshold,
            self.typo.suggest_threshold,
            self.typo.suppress_auto_commit_on_correction,
        )
    }

    pub fn from_toml_str(src: &str) -> Self {
        let mut cfg = Self::default();
        let mut section = String::new();
        for raw_line in src.lines() {
            let line = match raw_line.find('#') {
                Some(idx) => &raw_line[..idx],
                None => raw_line,
            }
            .trim();
            if line.is_empty() {
                continue;
            }
            if line.starts_with('[') && line.ends_with(']') {
                section = line[1..line.len() - 1].trim().to_ascii_lowercase();
                continue;
            }
            let Some(eq) = line.find('=') else {
                continue;
            };
            let key = line[..eq].trim();
            let val = line[eq + 1..].trim().trim_matches('"').trim_matches('\'');
            let parse_bool = |v: &str| matches!(v.to_ascii_lowercase().as_str(), "true" | "1" | "yes");

            match (section.as_str(), key) {
                (_, "schema") => cfg.schema = WubiSchema::from_str_tag(val),
                (_, "page_size") => {
                    if let Ok(n) = val.parse::<u8>() {
                        cfg.page_size = n.clamp(3, 9);
                    }
                }
                (_, "orientation") => cfg.orientation = CandidateOrientation::from_tag(val),
                (_, "shift_toggle_mode") => cfg.shift_toggle_mode = ShiftToggleMode::from_tag(val),
                (_, "smart_punctuation") => cfg.smart_punctuation = parse_bool(val),
                (_, "semicolon_quote_select") => cfg.semicolon_quote_select = parse_bool(val),
                (_, "fourth_code_auto_commit") => cfg.fourth_code_auto_commit = parse_bool(val),
                (_, "fifth_code_push_commit") => cfg.fifth_code_push_commit = parse_bool(val),
                (_, "fourth_empty_behavior") => {
                    cfg.fourth_empty_behavior = FourthEmptyBehavior::from_tag(val)
                }
                (_, "shortest_code_first") => cfg.shortest_code_first = parse_bool(val),
                (_, "strict_shortcode") => cfg.strict_shortcode = parse_bool(val),
                (_, "show_shortcode_hint") => cfg.show_shortcode_hint = parse_bool(val),
                (_, "dynamic_word_freq") => cfg.dynamic_word_freq = parse_bool(val),
                (_, "dynamic_char_freq") => cfg.dynamic_char_freq = parse_bool(val),
                (_, "auto_phrase") => cfg.auto_phrase = parse_bool(val),
                (_, "auto_phrase_threshold") => {
                    if let Ok(n) = val.parse::<u8>() {
                        cfg.auto_phrase_threshold = n.clamp(1, 5);
                    }
                }
                (_, "z_omnipotent") => cfg.z_omnipotent = parse_bool(val),
                (_, "enable_rare_charset") => cfg.enable_rare_charset = parse_bool(val),
                ("typo_correction", "enabled") | (_, "typo_enabled") => {
                    cfg.typo.enabled = parse_bool(val)
                }
                (_, "touch_hitbox_adapt") => cfg.typo.touch_hitbox_adapt = parse_bool(val),
                (_, "promote_threshold") => {
                    if let Ok(f) = val.parse::<f32>() {
                        cfg.typo.promote_threshold = f.clamp(0.50, 0.99);
                    }
                }
                (_, "suggest_threshold") => {
                    if let Ok(f) = val.parse::<f32>() {
                        cfg.typo.suggest_threshold = f.clamp(0.10, 0.85);
                    }
                }
                (_, "suppress_auto_commit_on_correction") => {
                    cfg.typo.suppress_auto_commit_on_correction = parse_bool(val)
                }
                _ => {}
            }
        }
        cfg
    }

    pub fn load_file<P: AsRef<Path>>(path: P) -> io::Result<Self> {
        let content = fs::read_to_string(path)?;
        Ok(Self::from_toml_str(&content))
    }

    pub fn save_file<P: AsRef<Path>>(&self, path: P) -> io::Result<()> {
        if let Some(parent) = path.as_ref().parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(path, self.to_toml_string())
    }
}
