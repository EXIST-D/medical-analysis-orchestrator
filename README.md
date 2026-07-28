# Medical Analysis Orchestrator Skill

[English](README.en.md) | 简体中文

`medical-analysis-orchestrator` 是一个面向 Codex 及兼容 Agent 的通用医学数据分析编排 Skill。它解决的不是“运行某一份固定统计脚本”，而是把用户提供的医学、临床或问卷数据推进为一条可检查、可确认、可复现、可审计的分析链：

```text
inspect → recommend → confirm → execute → report
```

Skill 先以只读方式识别文件、数据集、变量类型、缺失、重复和潜在研究角色；再根据研究问题、研究设计与数据条件提出统计方案；只有用户明确确认结局、变量、清洗规则和方法后，才调用 R 执行分析并生成表格、图形、运行记录和 Word 报告。

当前版本：`0.0.1`

发布状态：Beta / 技术预览版

## 为什么使用这个 Skill

- **不是固定分析流水线**：不把网络分析、贝叶斯网络或任何单一模型设为默认路径。
- **先判断数据适合做什么**：当用户没有指定方法时，先反馈数据结构、候选变量、适用方法、前提和限制。
- **关键决策必须确认**：不擅自决定主要结局、事件水平、分组、参照组、量表计分或病例排除。
- **R-first、模块化扩展**：当前统计计算由 R 完成，每种方法独立注册依赖与参数，后续可逐个增加新模块。
- **结果来源可追溯**：统一记录输入哈希、方案指纹、R 与包版本、随机种子、模型对象、输出文件和 manifest。
- **交付物工程化**：生成清晰编号的 CSV、三线表 XLSX、R 图形、Source Data、诊断信息和中文 Word 报告。
- **论文支持受控**：论文主张必须由用户确认并解析到同一次运行的表或图，不能根据显著性自动生成论文结论。

## 仓库结构

```text
medical-analysis-orchestrator/
├── README.md
├── README.en.md
├── LICENSE
├── VERSION
└── medical-analysis-orchestrator/
    ├── SKILL.md
    ├── LICENSE.txt
    ├── agents/
    │   └── openai.yaml
    ├── modules/
    ├── references/
    ├── scripts/
    └── templates/
```

仓库根目录保存面向使用者和贡献者的发布说明；真正安装到 Agent 的 Skill 位于 `medical-analysis-orchestrator/` 子目录。

## 核心工作模式

### 1. `inspect`

只读检查 CSV、Excel、DAT、SPSS、Stata、SAS、JSON 等常见数据，生成数据清单、变量字典、质量报告和清洗候选。候选变量角色不等于已经确认的研究角色。

### 2. `recommend`

结合研究问题、研究设计和数据结构提出描述性分析、组间比较、相关、回归、心理测量、纵向模型或其他候选方法，并说明：

- 适用条件；
- 关键统计假设；
- 所需变量；
- 缺失值策略；
- 诊断与替代方法；
- 当前数据不能支持的解释。

### 3. `confirm`

要求用户确认主要结局、事件编码、分组、参照组、协变量、清洗操作、缺失策略、模块参数和随机种子。配置发生变化后，原方案指纹自动失效，必须重新确认。

### 4. `execute`

生成清洁分析副本，自动发现 R，解析已确认模块的依赖，只把缺失或版本不足的包安装到项目级 Library，然后按注册顺序运行统计模块。

### 5. `report`

验证统一结果对象、文件哈希和模块顺序，只使用同一个 `run_id` 的结果生成 CSV、XLSX、图形、Source Data、模型对象、运行记录和 Word 报告。

## 0.0.1 可执行模块

| 模块 | 当前能力 | 状态 |
|---|---|---|
| `descriptive` | 连续变量与分类变量描述性统计 | `ready` |
| `group-comparison` | Welch t/ANOVA、Wilcoxon/Kruskal–Wallis、χ²/Fisher | `ready` |
| `correlation` | Pearson、Spearman、Kendall 与多重校正 | `ready` |
| `linear-regression` | 多元线性回归、共线性和残差诊断 | `ready` |
| `logistic-regression` | 二分类 Logistic 回归、OR、AUC、Brier 和 ROC | `ready` |
| `reliability-validity` | α、ω、条目分析、KMO、Bartlett 与效标关联 | `ready` |
| `factor-analysis` | EFA、平行分析、CFA、CR、AVE 和区分效度 | `ready` |
| `mixed-effects` | 连续结局 LMM 与二分类结局 GLMM | `ready` |

以下接口已经登记，但仍处于 `planned` 状态，不能生成正式结果：

- `generalized-regression`：有序、多分类、Poisson 和负二项回归；
- `gee`：广义估计方程；
- `measurement-invariance`：测量不变性；
- `survival`：生存分析；
- `network`：网络估计、稳定性、桥接指标和网络比较；
- `bayesian`：贝叶斯网络。

## 环境要求

- Windows 10/11 为当前主要验证平台；
- R `>= 4.3.0`；
- Python 3.11 或兼容版本；
- Python 编排依赖：`pandas`、`openpyxl`、`PyYAML`、`python-docx`、`pyreadstat`；
- R 包由确认后的模块按需解析和安装。

R 依赖默认安装到 Skill 的项目级 `.r-library`，不修改系统 R Library。`.r-library` 是本机运行产物，不属于源码发布包，本仓库已通过发布白名单与 `.gitignore` 双重排除。

## 安装方式

可以在 Codex 中使用 Skill Installer，并指向仓库中的 Skill 目录：

```text
$skill-installer install https://github.com/EXIST-D/medical-analysis-orchestrator/tree/main/medical-analysis-orchestrator
```

也可以手动克隆仓库，再将 `medical-analysis-orchestrator/` 子目录复制到 Codex 或兼容 Agent 的 Skills 目录。安装入口为：

```text
medical-analysis-orchestrator/SKILL.md
```

如果安装后没有立即出现该 Skill，请重启 Codex 或重新加载 Skills。

## 使用示例

只检查数据，不执行模型：

```text
使用 $medical-analysis-orchestrator 检查路径“<数据路径>”中的医学数据。
先输出文件清单、变量字典、数据质量问题和可选择的分析方法，不要执行推断模型。
```

让 Skill 推荐分析方案：

```text
使用 $medical-analysis-orchestrator 检查“<数据文件>”。
研究问题是“<研究问题>”。请识别结局、分组、时间和量表条目候选，
提出适合的医学统计方案、前提、限制和需要我确认的决策，然后停止等待确认。
```

执行已经明确的方法：

```text
使用 $medical-analysis-orchestrator 分析“<数据文件>”。
主要结局为“<结局变量>”，自变量为“<变量列表>”，分类变量参照组为“<参照组>”。
请执行描述性统计、单因素分析和 Logistic 回归，记录缺失处理、诊断、R 版本、
包版本和随机种子，并生成三线表 XLSX、R 图形和中文 Word 报告。
```

完整请求模板：

```text
使用 $medical-analysis-orchestrator，对“<项目目录>”中的“<数据文件>”开展医学统计分析。

研究问题：<研究问题>
研究设计：<横断面/病例对照/队列/随机试验/重复测量/其他>
主要结局：<变量及临床含义>
主要暴露或分组：<变量>
预期分析方法：<已指定方法；若不确定则写“请推荐”>

请先只读探查数据，生成变量字典、质量报告和分析建议。
不得擅自删除病例、异常值或修改量表计分。
列出所有需要确认的清洗与统计决策，并在我确认前停止。
确认后使用 R 执行分析，输出统一结果对象、三线表、图形 Source Data、
sessionInfo、包版本、manifest 和指定格式的 Word 报告。
```

## 主要输出

```text
analysis_plan.yml
data_profile.csv
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
sessionInfo.txt
package_versions.csv
manifest.json
```

统计表默认同时输出机器可读 CSV 与三线表 XLSX。工作簿不使用多余底色或装饰色，中文使用宋体，英文和数字使用 Times New Roman。Word 正文默认使用宋体小四、英文与数字 Times New Roman、1.5 倍行距和首行缩进 2 字符。

## 安全、隐私与统计边界

- 原始数据始终只读，只在运行目录生成清洁副本；
- 不为了显著性、预期方向或指定网络结构修改真实数据；
- 不自动删除异常值、病例或重复值；
- 不自动插补或改变量表计分、反向计分和理论维度；
- 不擅自选择主要结局、事件水平、分组变量、参照组或多重比较策略；
- 小样本、稀少事件、严重缺失、完全分离、不收敛或关键假设失败时警告或拒绝复杂模型；
- 横断面关联、网络边和贝叶斯网络方向不解释为确定因果关系；
- 报告只消费同一 `run_id` 下经过验证的统一结果对象；
- 默认不在日志、manifest 或报告中输出逐行患者数据。

本项目不是患者数据匿名化或去标识化工具。使用者必须自行确保数据使用符合所在机构的伦理审批、知情同意、隐私保护、数据治理和适用法律要求。

本项目不构成医疗建议、诊断或治疗建议，不能替代临床研究者、医学统计学家、数据安全人员或伦理审查。

## 验证状态

`0.0.1` 发布前已完成：

- 16 项自动化测试；
- Skill 结构校验；
- Python、R 和 YAML 语法检查；
- 本地文档链接检查；
- 真实 R 模块执行；
- 三线表、统计图、Source Data 和 Word 报告验证；
- 发布包 `.r-library`、缓存、运行产物和敏感信息排除检查。

当前主要验证环境为 Windows、R 4.6.1 和 Python 3.11。其他操作系统、R/Python 版本和复杂真实研究设计仍需进一步验证。

## 原创性与第三方依赖声明

本项目由作者独立设计和持续开发。核心工作流、确认门、模块注册表、配置契约、统一结果对象、图形证据契约、输出验证和报告编排均为本项目自身实现。

项目可以参考公开统计规范、软件文档和优秀工程实践，但不会把第三方 Skill、专有代码、真实患者数据或受限制材料直接打包为本项目内容。R、Python 及各统计包仍分别适用其自身许可证；MIT License 仅覆盖本仓库原创代码和文档，不改变第三方组件的许可条款。

## 作者与维护

本项目由 [EXIST-D](https://github.com/EXIST-D) 创建并维护。

欢迎通过 [GitHub Issues](https://github.com/EXIST-D/medical-analysis-orchestrator/issues) 提交问题、数据格式兼容性反馈、统计方法建议或功能需求。Pull Request 也同样欢迎；提交贡献即表示你有权提供相关内容，并同意该贡献按本仓库 MIT License 发布。

如果本项目在研究、教学、方法演示或软件工作流中对你有帮助，建议引用具体版本，以便结果复现：

```text
EXIST-D. medical-analysis-orchestrator (Version 0.0.1) [Computer software].
GitHub. https://github.com/EXIST-D/medical-analysis-orchestrator
```

## 许可证

本仓库采用 MIT License。详见 [LICENSE](LICENSE)。打包后的 Skill 内部也包含一份许可证副本：`medical-analysis-orchestrator/LICENSE.txt`。

MIT License 允许在保留版权与许可声明的前提下使用、复制、修改、合并、发布、分发、再许可和销售本软件。本软件按“原样”提供，不附带任何明示或默示保证；完整条款以 `LICENSE` 文件为准。
