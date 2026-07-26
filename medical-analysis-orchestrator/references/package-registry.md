# R 依赖按需注册

依赖来自已确认模块的 `module.yml`，不维护“一次安装全部包”的固定清单。

## 当前核心

| 用途 | 包 |
|---|---|
| 配置与结果序列化 | `yaml`, `jsonlite` |
| 文件指纹 | `digest` |
| 三线表 XLSX | `openxlsx2` |

基础五个统计模块的计算主要使用 base R；`pROC` 是 Logistic 模块的可选扩展，不是当前 ROC 计算的硬依赖。

## 当前扩展模块

| 模块 | 必需包 | 说明 |
|---|---|---|
| 信度与效度 | `psych`, `openxlsx2` | α、ω、条目分析、KMO、Bartlett、效标关联 |
| EFA/CFA | `psych`, `lavaan`, `openxlsx2` | EFA、平行分析、CFA、拟合与效度指标 |
| 混合效应模型 | `lme4`, `lmerTest`, `openxlsx2` | LMM 使用 Satterthwaite 检验；GLMM 使用 `lme4` |

## 后续模块候选

| 模块 | 候选包 |
|---|---|
| 生存分析 | `survival`, `survminer`, `cmprsk` |
| GEE/复杂广义混合模型 | `geepack`, `glmmTMB` |
| 测量不变性/高级 SEM | `semTools` |
| 网络分析 | `qgraph`, `bootnet`, `networktools`, `NetworkComparisonTest` |
| 贝叶斯网络 | `bnlearn`, `igraph` |

候选包只在对应模块确认并升级为 `ready` 后按需解析。

## 安装规则

1. 自动发现 R 及 `.libPaths()`。
2. 合并已确认模块的 `required_packages`，取最高最低版本。
3. 已安装且满足版本时直接复用。
4. 缺失或过旧时只安装到 Skill 的 `.r-library`。
5. 不修改系统 Library，不升级无关包。
6. 安装临时目录设在当前运行的 `runtime/r-install-tmp`。
7. 安装日志写入 `99_运行记录`，包版本写入 `package_versions.csv`。
8. 安装失败时停止依赖该包的运行，并报告包名、版本和错误。
9. `renv.lock` 仅在配置启用且用户确认时生成或更新。

## Python 编排依赖

推荐环境需要 `pandas`、`openpyxl`、`PyYAML`、`python-docx`、`pyreadstat` 和 `pytest`。Python 负责探查、契约、验证和报告；统计计算仍由 R 模块完成。
