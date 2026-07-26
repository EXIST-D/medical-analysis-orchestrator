# 分析配置契约（schema 1.1）

唯一配置模板为 `templates/analysis_config.yml`。

## 关键区块

| 区块 | 内容 | 执行前约束 |
|---|---|---|
| `run` | `run_id`、模式、输出目录、随机种子 | `run_id` 唯一，种子为正整数 |
| `input` | 原始路径、格式、sheet、编码、SHA-256、清洁副本路径 | `read_only: true`；执行时必须是单文件并有 SHA-256 |
| `research` | 研究问题、设计、目标与 estimand | 主要问题不能为空 |
| `variables` | ID、结局、暴露、协变量、分类变量、分组、时间、事件、参照水平、标签和单位 | 角色由用户确认 |
| `data_handling` | 自动动作、确认动作、缺失、重复、异常值、排除、转换和多重校正 | 不允许隐式改变分析样本 |
| `analysis` | 模块列表和模块参数 | 模块已注册且状态为 `ready` |
| `runtime` | R 自动发现、最低版本、项目 Library、仓库和 renv | 当前统计引擎必须为 R |
| `reporting` | 表格、R 图形契约、论文支持、隐私、Word 和工作簿格式 | 图形后端、Source Data、主张证据边界明确 |
| `decisions_required` | 尚未解决的关键决策 | 执行前必须为空 |
| `approval` | 确认状态、人、时间、方案指纹和备注 | 执行前完整且指纹匹配 |

## 方案指纹

确认时移除 `approval` 区块，对其余规范化配置计算 SHA-256，写入 `approval.plan_sha256`。执行前重新计算；任何修改都要求重新确认。

## 路径规则

- 相对数据与输出路径以配置文件所在目录解析。
- `runtime.project_library` 相对路径以 Skill 根目录解析。
- 原始数据不得成为输出目标。
- 正式执行一次只接受一个明确的数据文件；多文件应先探查并在确认的合并方案下生成分析副本。

## 模块参数

当前参数位于：

```text
analysis.parameters.descriptive
analysis.parameters.group-comparison
analysis.parameters.correlation
analysis.parameters.linear-regression
analysis.parameters.logistic-regression
analysis.parameters.reliability-validity
analysis.parameters.factor-analysis
analysis.parameters.mixed-effects
```

模块描述符中的 `required_config` 会在执行前动态校验。

扩展模块还执行专门的确认校验：信效度模块要求具名量表和每量表至少 3 个条目；EFA 要求确认因子数，CFA 要求明确 `lavaan` 模型语法；混合效应模型要求结局、固定效应和分组变量，二分类模型还必须确认事件水平。

## R 图形契约

`reporting.figure_contract` 包含：

```text
profile
backend
formats
width_mm
height_mm
dpi
require_source_data
require_statistics_metadata
require_editable_text
```

`backend` 固定为 `R`。`analysis` 档位可只输出 PNG；`manuscript` 档位必须包含 PNG、SVG、PDF 和 TIFF，至少 300 dpi，并要求可编辑矢量文字。

## 论文写作支持

`reporting.manuscript_support` 默认关闭。启用时必须：

- 分离结果与解释；
- 输出统计方法与可复现性摘要；
- 生成术语账本；
- 至少登记一条用户确认的主张；
- 为每条主张登记稳定证据引用、解释层级和边界；
- 使用唯一主张 ID。

证据引用格式为 `module_id:table_id` 或 `module_id:figure_id`，执行后必须解析到本次统一结果对象。
