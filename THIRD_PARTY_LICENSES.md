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

## 纠错语言模型统计语料来源（`wubi_aux.wbaux` `WBAUX002`）

`Resources/Dicts/wubi_aux.wbaux` 中的字级 Unigram、Bigram PMI 与 Trigram 残差统计表（不包含任何原始语料原文，仅保留聚合频次/对数概率统计）由 `Scripts/prepare_corpus.py` 与 `Core/src/bin/train_lm.rs` 基于以下多域中文语料（40% 正式书面 / 30% 社区问答 / 30% 社交短评，另含 2.5% Rime 词表回退）训练并经 `build-dicts --corpus-lm` 编译生成：

| 语料分组 | 上游数据集 | 采样规模（训练汉字） | 上游协议声明 | 分发/商用合规提示 |
| --- | --- | --- | --- | --- |
| 正式书面 (Formal) | [wikimedia/wikipedia (`20231101.zh`)](https://huggingface.co/datasets/wikimedia/wikipedia) | 20.00M（繁转简并过滤自动生成小条目） | `CC-BY-SA-4.0` & `GFDL` | 需署名；统计派生权重建议保留来源说明 |
| 社区问答 (Community) | [KrisTHL181/zhihu-qa](https://huggingface.co/datasets/KrisTHL181/zhihu-qa)（筛 2025–2026） | 16.00M | `ODC-BY` | 需署名；原始抓取内容受平台条款约束 |
| 社区问答 (Community) | [nlgandnlu/ZHIHU-16K](https://github.com/nlgandnlu/ZHIHU-16K) | 6.00M | 未显式声明（学术公开） | 仅建议研究/个人评估使用 |
| 社交口语 (Social) | [Orphanage/Baidu_Tieba_KangYaBeiGuo](https://huggingface.co/datasets/Orphanage/Baidu_Tieba_KangYaBeiGuo) | 2.01M | 卡片标 `MIT` / README 标 `CC-BY-NC-4.0` | **含非商用限制**，公开发布商业版本前请核查或替换 |
| 社交口语 (Social) | [FreshCrawl/rednote-xiaohongshu-notes](https://huggingface.co/datasets/FreshCrawl/rednote-xiaohongshu-notes) | 1.49M | `Research-only`（非商用研究） | **仅限非商用研究**，公开发布商业版本前需剥离或替换 |
| 社交口语 (Social) | [xinjiexinjie/socialbots](https://github.com/xinjiexinjie/socialbots)（2025 小红书评论） | 0.38M | 未显式声明（学术公开） | 仅建议研究/个人评估使用 |

> 若需构建严格纯宽松协议的独立版 `wubi_aux.wbaux`（不引入任何外部社区/社交语料），可直接运行 `make dicts`（不传 `FORMORDO_CORPUS_LM`），退回仅由 `Resources/RawTables/` 生成的基础 Bigram 统计。

## 派生二进制产物与协议兼容性提示

- `Resources/Dicts/wubi86.wbdict`、`wubi98.wbdict`、`wubi06.wbdict` 分别是对应原始码表的直接二进制索引编译产物，沿用各自原始码表的开源协议（`LGPL-3.0` / `GPL-3.0` / `Apache-2.0`）。
- `Resources/Dicts/wubi_aux.wbaux`（`WBAUX002`）汇总了 `mozillazg/pinyin-data` 的拼音反查索引、三套五笔词表的回退统计，以及上述多域语料派生的 7,330 条 Unigram、260,000 条 Bigram PMI 与 150,000 条 Trigram 残差统计。分发 `Resources/Dicts/` 时需同时遵守 `GPL-3.0` / `LGPL-3.0` / `Apache-2.0` / `MIT` 条款，并留意上表所列社区/社交语料的非商用/研究用途限制（公开发布商业 App Store 版本前建议替换为明确可商用的授权语料重新执行 `train_lm` + `build-dicts --corpus-lm`）。
