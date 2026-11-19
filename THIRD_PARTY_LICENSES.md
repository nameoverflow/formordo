# Third-Party Data & Licenses

形序 (Formordo) 的离线词典（`Resources/Dicts/*.wbdict` 与 `Resources/Dicts/wubi_aux.wbaux`）由 `Core/src/bin/build_dicts.rs` 从 `Resources/RawTables/` 中的以下第三方开源码表与拼音数据直接编译生成（可通过 `make dicts` 完全复现）：

| 资源目录 | 上游仓库 | 固定提交 (Commit) | 包含文件 | 对应编译产物 | 开源协议 (SPDX) | 协议原文 |
| --- | --- | --- | --- | --- | --- | --- |
| `Resources/RawTables/wubi86/` | [rime/rime-wubi](https://github.com/rime/rime-wubi) | `152a0d3f3efe40cae216d1e3b338242446848d07` | `wubi86.dict.yaml`, `AUTHORS`, `LICENSE` | `wubi86.wbdict`, `wubi_aux.wbaux` | `LGPL-3.0-only` | [wubi86/LICENSE](Resources/RawTables/wubi86/LICENSE) |
| `Resources/RawTables/wubi98/` | [lotem/rime-wubi98](https://github.com/lotem/rime-wubi98) | `0bc5b2b296f536d38ffe38381d37e5011da55e59` | `wubi98.dict.yaml`, `LICENSE` | `wubi98.wbdict`, `wubi_aux.wbaux` | `GPL-3.0-only` | [wubi98/LICENSE](Resources/RawTables/wubi98/LICENSE) |
| `Resources/RawTables/wubi06/` | [g178253/rime-wubi06](https://github.com/g178253/rime-wubi06) | `b10733bb001c0b38917577f51d78834bdc56a35f` | `wubi06.dict.yaml`, `LICENSE` | `wubi06.wbdict`, `wubi_aux.wbaux` | `Apache-2.0` | [wubi06/LICENSE](Resources/RawTables/wubi06/LICENSE) |
| `Resources/RawTables/pinyin/` | [mozillazg/pinyin-data](https://github.com/mozillazg/pinyin-data) (v0.16.0) | `fe29ad32bdf352b31a02b9936e537f575432e9a6` | `kTGHZ2013.txt`, `kMandarin_8105.txt`, `pinyin.txt`, `LICENSE` | `wubi_aux.wbaux` | `MIT` | [pinyin/LICENSE](Resources/RawTables/pinyin/LICENSE) |

## 著作权与衍生来源说明

1. **`rime/rime-wubi`（五笔 86 版）**
   - 协议：GNU Lesser General Public License v3.0 (`LGPL-3.0`)。
   - 署名（摘自 `AUTHORS` 与 `wubi86.dict.yaml` 头部）：衍生自 Yu Yuwei (`acevery`) 维护的 `ibus-table`（LGPL）及陈兴、Gong Chen 等人的整理转换，基础字根与码表源自王永民先生（Public Domain）。
2. **`lotem/rime-wubi98`（五笔 98 版）**
   - 协议：GNU General Public License v3.0 (`GPL-3.0`)，声明于 `wubi98.dict.yaml` 文件头部 `# license: GPLv3`。
   - 署名：衍生自 `https://github.com/acevery/ibus-table-wubi`，由 Gong Chen (`lotem`) 整理为 Rime 词典格式。上游仓库未附独立文本文件，本仓库已在 `Resources/RawTables/wubi98/LICENSE` 补齐官方 GPL-3.0 协议全文。
3. **`g178253/rime-wubi06`（新世纪 / 06 版五笔）**
   - 协议：Apache License 2.0 (`Apache-2.0`)，协议原文见 `Resources/RawTables/wubi06/LICENSE`。
4. **`mozillazg/pinyin-data`（拼音反查与通用规范汉字表）**
   - 协议：MIT License (`MIT`)，Copyright (c) 2016 mozillazg，协议原文见 `Resources/RawTables/pinyin/LICENSE`。
   - 原始数据整合自 [Unicode Unihan Database](https://www.unicode.org/reports/tr38/)（`kTGHZ2013` / `kMandarin` 等字段）及《通用规范汉字表》（2013 年版）。

## 派生二进制产物与协议兼容性提示

- `Resources/Dicts/wubi86.wbdict`、`wubi98.wbdict`、`wubi06.wbdict` 分别是对应原始码表的直接二进制索引编译产物，沿用各自原始码表的开源协议（`LGPL-3.0` / `GPL-3.0` / `Apache-2.0`）。
- `Resources/Dicts/wubi_aux.wbaux` 同时汇总了 `mozillazg/pinyin-data` 的拼音反查索引以及从三套五笔词表的多字词词频派生的 55,000 条字级 PMI Bigram。由于其中包含源自 `wubi98.dict.yaml`（`GPL-3.0`）的派生统计数据，整体分发 `Resources/Dicts/` 时需同时遵守 `GPL-3.0` / `LGPL-3.0` / `Apache-2.0` / `MIT` 各自条款（保留版权与协议声明，并提供对应的原始码表与构建脚本 `Core/src/bin/build_dicts.rs`，均已完整收录于本仓库）。
