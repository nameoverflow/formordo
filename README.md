# 棱五笔 (PrisWubi)

面向 **macOS (`InputMethodKit`)** 与 **iOS (`UIInputViewController` 虚拟键盘扩展 + SwiftUI 宿主 App)** 的极速精简原生五笔输入法。

## 核心特性

1. **零外部依赖、零拷贝 `mmap` 通用内核 (`Core/wubi-core`)**：
   - 纯 Rust `std` + POSIX `mmap`，`[dependencies]` 为零，同时编译为 `aarch64-apple-darwin`、`aarch64-apple-ios` 与 `aarch64-apple-ios-sim` 静态库。
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
   - **macOS (`Sources/`)**：无边框 `NSPanel` + `NSVisualEffectView` 原生毛玻璃候选浮窗（横/竖排、深/浅色自适应）、系统设置风格偏好面板（内置触屏热区实时演练台）、输入法菜单栏快捷切表。
   - **iOS (`iOS/`)**：
     - **`PrisWubiKeyboard` 虚拟键盘扩展 (`iOS/KeyboardExtension/`)**：1:1 原生 4 行键帽几何、三层键盘（`ABC` 26 键 / `123` 数字与中英标点 / `#+=` 符号）、连颈式按键放大气泡（Key Callout）、长按/横滑空格光标触控板、长按退格加速连删、动态蓝色高亮回车键、横向候选条 + `⌄` 四列全屏展开候选面板、免「允许完全访问」键盘内快捷设置与系统按键音。
     - **`PrisWubiApp` 宿主应用 (`iOS/HostApp/`)**：三步启用引导与实时打字试手框、五笔规则配置、**26 键个人触控热区偏移图**、App Group 跨进程词库同步管理。

## 构建与验证

```sh
make test          # 运行 Rust 核心测试 + macOS Swift 桥接测试 + iOS 键盘几何与视口触点测试
make app           # 编译并签名 macOS 输入法 build/PrisWubi.app
make install       # 安装并注册至 ~/Library/Input Methods/PrisWubi.app
make ios-core      # 交叉编译 iOS 真机 (aarch64-apple-ios) 与模拟器静态库
make ios-project   # 使用 XcodeGen 生成 iOS/PrisWubi.xcodeproj
make previews      # 渲染 macOS 2x Retina 候选窗与设置页预览图
make ios-previews  # 渲染 iPhone 2x Retina 虚拟键盘与宿主 App 预览图
```

### 真机 / 模拟器运行 iOS 端
在装有完整 `Xcode.app` 的 Mac 上直接打开 `iOS/PrisWubi.xcodeproj`，选择 `PrisWubiApp` Scheme（在 Signing & Capabilities 选定你的开发 Team 并确认 App Group `group.com.priswubi.shared`），按 `⌘R` 即可自动触发 `iOS/Scripts/build-rust-ios.sh` 编译 Rust 静态库并安装到 iPhone 或模拟器。仓库同时附带 `.github/workflows/build.yml` 自动构建双端产物。
