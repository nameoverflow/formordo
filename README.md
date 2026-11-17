# 棱五笔 (PrisWubi)

面向 **macOS (`InputMethodKit`)** 与 **iOS (`UIInputViewController` 虚拟键盘扩展)** 的极速精简原生五笔输入法。

## 核心特性

1. **零外部依赖、零拷贝 `mmap` 通用内核 (`Core/wubi-core`)**：
   - 纯 Rust `std` + POSIX `mmap`，`[dependencies]` 为零。
   - 1–4 码五笔采用保序 Base-27 `u32` 定长分桶，编译生成紧凑只读词典（`wubi86.wbdict` / `wubi98.wbdict` / `wubi06.wbdict` + `wubi_aux.wbaux`）。
   - 冷启动映射 `< 1 ms`，单次击键含 24-beam 误触解码平均耗时 **~21 μs**，iOS 键盘扩展 Dirty RSS 接近 0。
2. **86 / 98 / 新世纪 (06) 三版本与跨版本动态组词**：
   - 运行时毫秒级热切换三套标准码表。
   - 个人词库与连打自动组词仅保存词条文本，按当前激活版本的单字字根（`stem2`）实时遵循 `AaAbBaBb` / `AaBaCaCb` / `AaBaCaZa` 推导编码，切版本无需重造词。
3. **统计置信度 + 连续触控热区自适应纠错 (`Core/src/typo.rs`)**：
   - 融合 **2D 连续触点高斯对数似然** + **5.5 万条语料 PMI Bigram** + **个人历史 Unigram/Bigram**，经 Softmax 产出归一化后验置信度 $p \in [0, 1]$。
   - 支持 **空码救回**、**两键交界滑偏重判 (Soft Voronoi Hitbox)**、**双指快速换位纠错 (`ab -> ba`)**，以及 **每键个人拇指偏移 EMA 在线自适应校准**（限幅 `±0.20` 键宽防跑偏）。
   - 默认对非精确纠错项抑制「四码唯一盲目自动上屏」，绝不乱顶错字。
4. **贴合苹果原生的双端界面**：
   - **macOS (`Sources/`)**：无边框 `NSPanel` + `NSVisualEffectView` 原生毛玻璃候选浮窗（横/竖排、深/浅色自适应）、系统设置风格偏好面板（内置 iOS 26 键触屏热区实时演练台）、输入法菜单栏快捷切表。
   - **iOS (`iOS/KeyboardViewController.swift`)**：对齐原生 26 键比例、按键放大气泡、空格长按光标触控板、`UIInputViewAudioFeedback` 免完全访问按键音，并将真实 `UITouch` 连续坐标直传 `wubi-core`。

## 构建与安装 (macOS)

```sh
make test       # 运行 Rust 单元/实测基准测试 + Swift FFI 桥接测试
make app        # 编译并签名 build/PrisWubi.app
make install    # 安装并注册至 ~/Library/Input Methods/PrisWubi.app
make previews   # 离线生成 2x Retina 候选窗与设置页预览图
```
