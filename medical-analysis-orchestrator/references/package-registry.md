# R 依赖按需注册

依赖来自已确认模块的 `module.yml`，不维护“一次安装全部包”的固定清单。

## 当前核心

| 用途 | 包 |
|---|---|
| 配置与结果序列化 | `yaml`, `jsonlite` |
| 文件指纹 | `digest` |
| 三线表 XLSX | `openxlsx2` |
| 默认学术绘图模板 | `ggplot2`, `patchwork`, `ragg`, `svglite`, `png` |

基础统计模块的计算尽量使用 base R；独立的诊断准确性模块把 `pROC` 作为必需依赖，Logistic 回归自身仍不依赖它。

## 当前扩展模块

| 模块 | 必需包 | 说明 |
|---|---|---|
| 信度与效度 | `psych`, `openxlsx2` | α、ω、条目分析、KMO、Bartlett、效标关联 |
| EFA/CFA | `psych`, `lavaan`, `openxlsx2` | EFA、平行分析、CFA、拟合与效度指标 |
| 混合效应模型 | `lme4`, `lmerTest`, `openxlsx2` | LMM 使用 Satterthwaite 检验；GLMM 使用 `lme4` |
| 缺失数据与多重插补 | `mice`, `openxlsx2` | 缺失审计和 MICE 插补对象 |
| 有序/多项/计数回归 | `MASS`, `nnet`, `openxlsx2` | `polr`、`multinom`、Poisson、负二项 |
| 基础生存分析 | `survival`, `openxlsx2` | Kaplan–Meier、log-rank、Cox、Schoenfeld 诊断 |
| 诊断准确性 | `pROC`, `openxlsx2` | ROC、AUC、阈值指标和 DeLong 比较 |
| GEE | `geepack`, `openxlsx2` | 群体平均效应和稳健方差 |
| 测量不变性/SEM | `lavaan`, `openxlsx2` | 多组 CFA 不变性与结构方程模型 |
| 竞争风险 | `cmprsk`, `openxlsx2` | 累积发生函数、Gray、Fine–Gray |
| 倾向评分 | `survey`, `openxlsx2` | IPTW/重叠权重和稳健加权推断 |
| 网络分析 | `qgraph`, `openxlsx2` | EBICglasso 与非参数 Bootstrap |
| 贝叶斯网络 | `bnlearn`, `igraph`, `openxlsx2` | 结构学习、边强度和平均网络 |

`networktools` 是网络桥接指标的可选依赖；只有配置确实需要扩展实现时才安装。未实现的零膨胀、网络组间比较和自动因果方向识别不得通过安装额外包偷偷启用。

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
