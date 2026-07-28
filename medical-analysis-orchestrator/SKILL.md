---
name: medical-analysis-orchestrator
description: 通用医学数据分析编排 Skill。用于读取用户指定的 CSV、Excel、DAT、SPSS、Stata、SAS、JSON 等医学或问卷数据，先以只读方式完成数据盘点、变量字典、质量报告和分析建议，再在用户明确确认结局、变量、清洗规则和统计方案后，自动发现 R、按模块安装项目级依赖、执行描述性统计、单因素分析、相关分析、多元线性回归、Logistic 回归、信效度分析、EFA/CFA 或混合效应模型，验证统一结果对象，并输出三线表 XLSX、由 R 生成且带 Source Data 的图形和指定中文格式的 Word 报告；可选生成投稿图形包、主张—证据—边界表、术语账本和统计方法可复现性摘要。网络分析等复杂方法仅作为后续可选模块，不是默认流程。
---

# 通用医学数据分析编排

本 Skill 是“先探查、再建议、经确认后执行”的编排器，不是一份固定统计脚本。没有用户确认时，只能执行 `inspect` 和 `recommend`，不得安装 R 包、清洗数据或运行推断模型。

## 固定工作流

按以下状态顺序工作：

1. `inspect`：只读盘点输入，生成变量字典、质量报告和清洗候选。
2. `recommend`：结合研究问题、设计和数据结构提出候选方法与限制。
3. `confirm`：解决所有 `decisions_required`，记录明确确认和方案指纹。
4. `execute`：生成清洁分析副本，发现 R，按需准备依赖，执行已确认模块。
5. `report`：验证统一结果对象，生成三线表、图形和 Word 报告。

用户未指定下一步时，在 `recommend` 后停止并询问是否执行建议方案。

## 不可违反的约束

- 原始数据始终只读；只在运行目录中创建清洁副本。
- 不为获得显著性、预期方向或指定网络结构修改真实数据。
- 不自动删除异常值、重复值或病例，不自动插补，不自动改变量表计分。
- 不擅自指定主要结局、事件水平、分组变量、参照组或多重比较策略。
- 所有需确认清洗动作必须含确认人、确认时间和理由，并写入清洗日志。
- 小样本、稀少事件、严重缺失、完全分离、不收敛或关键假设失败时，警告或拒绝复杂模型；Logistic 默认在疑似分离时安全停止。
- 横断面关联、网络边和贝叶斯网络方向不得表述为确定因果关系。
- 报告只能消费同一 `run_id` 下已验证的统一结果对象，不能手工拼接不同运行结果。
- 记录输入 SHA-256、方案 SHA-256、R 版本、包版本、随机种子、模型对象和输出文件哈希。
- 默认不在日志、manifest 或报告中输出逐行患者数据。
- 所有统计图形由 R 生成；Python 只允许编排、验证和嵌入报告，不得重新计算或重绘。
- 每张定量图必须登记 Source Data、证据角色、结论边界和完整统计元数据。
- 论文级主张必须由用户确认并解析到同一运行的表或图；不得由显著性结果自动生成论文结论。

处理输入和清洗时读取：

- [数据输入契约](references/data-input-contract.md)
- [变量字典契约](references/variable-dictionary-contract.md)
- [数据质量规则](references/data-quality-rules.md)
- [清洗策略](references/cleaning-policy.md)

选择或执行统计方法时读取：

- [方法选择规则](references/method-selection-rules.md)
- [心理测量与因子分析规则](references/psychometrics-rules.md)
- [混合效应模型规则](references/mixed-effects-rules.md)
- [配置结构](references/config-schema.md)
- [模块接口](references/module-contract.md)
- [包注册表](references/package-registry.md)

验证或报告时读取：

- [统一结果对象](references/result-object-schema.md)
- [输出契约](references/output-contract.md)
- [报告模板](references/report-template.md)
- 制作或验证统计图时读取 [R 图形证据契约](references/r-figure-contract.md)。
- 启用论文写作支持时读取 [科学写作支持契约](references/scientific-writing-contract.md)。
- 组织学术结果、图注或讨论边界时同时读取 [学术报告表述与报告风格](references/academic-reporting-style.md)。

## 1. 数据探查

运行：

```text
python scripts/inspect_data.py "<数据文件或目录>" --output "<run目录>"
```

探查至少反馈文件数量与格式、数据集数量、样本量、变量数、缺失、重复、变量类型、常量列、高基数列，以及候选 ID、结局、分组、时间、事件和量表条目。候选角色不是确认角色。

探查阶段生成：

```text
data_inventory.json
data_profile.json
data_profile.csv
01_数据整理/01_变量字典.xlsx
01_数据整理/02_数据质量报告.xlsx
01_数据整理/03_清洗操作候选.csv
manifest.json
```

## 2. 分析建议

运行：

```text
python scripts/recommend_analysis.py --profile "<run目录>/data_profile.json" --output "<run目录>/analysis_plan.yml" --research-question "<研究问题>"
```

建议必须说明方法、适用条件、关键假设、所需变量、缺失值策略、诊断、替代方法和不能支持的解释。无法从数据确定的内容写入 `decisions_required`。

当前已可执行模块：

- `descriptive`：连续变量与分类变量描述性统计。
- `group-comparison`：Welch t/ANOVA、配对 t、Wilcoxon/Kruskal–Wallis、配对 Wilcoxon、χ²/Fisher，以及确认后的 Tukey 或成对非参数事后比较。
- `correlation`：Pearson、Spearman、Kendall、多重校正与变量对有效样本量矩阵。
- `linear-regression`：多元线性回归、HC3 稳健标准误、共线性和残差诊断。
- `logistic-regression`：二元 Logistic 回归、OR、EPV、AUC、Brier、表观校准、ROC 与分离安全处理。
- `reliability-validity`：Cronbach’s α、McDonald’s ω、条目分析、KMO、Bartlett、可选效标关联，以及有序条目的多分相关支持。
- `factor-analysis`：EFA、平行分析、CFA、拟合指标、组合信度、AVE、区分效度、修改指数审计和可选 EFA/CFA 独立样本划分。
- `mixed-effects`：连续结局 LMM 与二分类结局 GLMM，支持随机截距/斜率、交互项和拟合诊断。

`generalized-regression`、`gee`、`measurement-invariance`、`survival`、`network`、`bayesian` 仍是后续扩展，不得以 `planned` 描述符生成正式结果。

## 3. 确认方案

从 [templates/analysis_config.yml](templates/analysis_config.yml) 补齐配置，尤其是：

- 研究问题与研究设计；
- 主要结局、事件水平、分组变量、预测变量与参照水平；
- 缺失值、排除、重编码和转换规则；
- 模块与参数；
- 随机种子和输出目录。

只有 `decisions_required` 为空时才能运行：

```text
python scripts/confirm_plan.py "<run目录>/analysis_plan.yml" --confirmed-by "<确认人>"
```

随后必须通过：

```text
python scripts/validate_config.py "<run目录>/analysis_plan.yml" --mode execute
```

配置变化会使方案指纹失效，必须重新确认。

## 4. R 环境与依赖

运行时通过 `scripts/detect_r_environment.py` 依次检查配置路径、项目线索、`R_HOME`、`PATH`、Windows 注册表和常见安装位置。不得在 Skill 中固定机器路径。`scripts/detect_python_environment.py` 会按输入格式识别 `openpyxl`、`xlrd`、`pyreadstat` 或 `pyarrow` 等 Python 依赖；只安装本次格式所需且缺失的包。

每个 `module.yml` 声明自身 `required_packages` 和最低版本。只安装缺失或过旧的包到 Skill 的 `.r-library`，不修改系统 R Library。安装临时目录、安装日志和运行日志也必须位于当前运行目录或 Skill 目录。

基础统计模块主要使用 base R；心理测量、因子分析和混合效应模块按需使用 `psych`、`lavaan`、`lme4`、`lmerTest`。所有模块使用项目级 `openxlsx2` 生成三线表工作簿。统计图形的预览和正式导出均由 R 完成；Python 仅负责数据编排、契约、文件验证、论文支持制品和 Word 报告。`runtime.use_renv` 支持 `off`、`snapshot` 和 `restore`；每次运行输出 `renv.lock`、Python 锁定文件和双环境清单。

## 5. 执行闭环

用户确认后运行：

```text
python scripts/run_pipeline.py --config "<run目录>/analysis_plan.yml"
```

流水线依次：

1. 校验方案与指纹；
2. 校验原始文件 SHA-256；
3. 创建清洁分析副本和清洗日志；
4. 检测输入格式能力并按需准备 Python 依赖，自动发现 R；
5. 解析模块依赖并按需安装到项目 Library；
6. 按注册顺序执行 R 模块；
7. 保存统一 JSON/RDS 结果对象、模型对象、图形和表格，并锁定运行环境；
8. 重建 manifest 并校验文件哈希与模块顺序；
9. 只从已验证结果生成 Word 报告和学术表述审计；
10. 在可用时对 Word/XLSX 做 LibreOffice 页面渲染回归，并再次执行 report 级验证。

## 6. 输出格式

目录按分析顺序编号：

```text
01_数据整理/
02_描述性统计/
03_单因素分析/
04_相关性分析/
05_多元线性回归/
06_Logistic回归/
07_信度与效度分析/
08_探索性与验证性因子分析/
09_混合效应模型/
90_最终报告/
99_运行记录/
runtime/
```

XLSX 使用无底色、无多余颜色、隐藏网格线的三线表；中文宋体，英文和数字 Times New Roman。CSV 保持机器可读，不承诺字体和边框。

Word 正文中文宋体、英文和数字 Times New Roman、小四 12 pt、1.5 倍行距、首行缩进 2 字符。表格与图形来自同一统一结果对象，完整高维表保留在 CSV/XLSX，Word 只展示适合阅读的摘要。

当配置 `reporting.visual_regression.require_renderer: true` 时，缺少 LibreOffice 页面渲染器将使报告阶段失败；默认模式会登记“渲染器不可用”，但不声称已完成视觉审查。

图形使用 `reporting.figure_contract.profile` 控制：

- `analysis`：常规报告档位，默认 PNG，但仍要求 R 生成、Source Data 和统计元数据。
- `manuscript`：论文档位，要求 PNG、SVG、PDF、TIFF 和 Source Data。

论文写作支持默认关闭。只有用户确认 `reporting.manuscript_support.claims` 后才生成主张—证据—边界表、统计方法与可复现性摘要、术语账本，并写入 Word；不得从 P 值或模型方向自动起草论文主张。

## 7. 新模块接入

新方法必须：

1. 在 `modules/<id>/module.yml` 声明状态、入口、必需配置、依赖和输出；
2. 实现 `run_module(config, context)`；
3. 返回 [统一结果对象](references/result-object-schema.md)；
4. 使用共享表格输出器和 R 图形证据接口；
5. 记录诊断、警告、限制、样本流、图形 Source Data 和统计元数据；
6. 添加成功、拒绝和端到端测试；
7. 通过验证后才把状态改为 `ready`。

网络分析等复杂模块最后接入，且始终由研究问题和已确认方案触发。
