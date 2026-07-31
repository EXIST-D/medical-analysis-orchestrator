# 输出与命名契约

每个运行使用独立目录和 `run_id`，所有正式结果必须追溯到同一输入指纹和方案指纹。

## 标准目录

```text
analysis_plan.yml
data_inventory.json
data_profile.json
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
10_缺失数据与多重插补/
20_扩展广义回归/
21_基础生存分析/
22_诊断试验准确性/
23_广义估计方程/
24_测量不变性/
25_竞争风险分析/
26_倾向评分分析/
27_结构方程模型/
30_网络分析/
31_贝叶斯网络/
90_最终报告/
99_运行记录/
runtime/
analysis_results.json
analysis_results.rds
execution_status.json
sessionInfo.txt
package_versions.csv
renv.lock
manifest.json
validation_report.json
```

`runtime/` 至少记录 `python_environment.json`、`python_requirements.lock.json`、`r_environment.json`、`renv_status.json` 和 `environment_manifest.json`。这些清单只记录版本、能力和锁定状态，不记录患者级数据。

未选中的模块目录不必创建。文件名使用“序号_内容”形式，不使用“最终版2”“新结果”等含糊命名。

启用 `manuscript_support` 后，`90_最终报告/` 还必须包含：

```text
02_主张证据边界表.csv
03_统计方法与可复现性.md
04_术语账本.yml
05_学术报告表述审计.md
```

启用视觉回归时，`90_最终报告/visual_regression/visual_regression.json` 记录 Word/XLSX 的渲染能力、PDF/页面指纹或明确的不可用状态。

## manifest

`manifest.json` 至少记录：

- `run_id`、阶段和时间；
- 输入文件指纹；
- 方案指纹和随机种子；
- 每个 artifact 的相对路径、类型、字节数、SHA-256、时间和来源模块；
- 警告与验证状态。

manifest 不记录逐行患者内容，也不对自身或验证报告形成循环哈希。

## 验证门槛

`scripts/validate_outputs.py` 检查：

- 阶段必需文件；
- 运行 ID、模块集合与顺序；
- 方案指纹；
- manifest 文件哈希；
- 统一结果对象字段；
- 表格、图形和模型对象存在性；
- 完成且带警告状态必须实际登记警告。
- 图形必须由 R 生成并登记 Source Data、统计元数据和全部确认格式。
- 投稿图形档位必须包含 PNG、SVG、PDF 和 TIFF。
- 论文主张的证据引用必须解析到同一统一结果对象。
- 诊断状态必须属于受控枚举，不能用任意文本伪装为通过。
- `reporting.visual_regression.require_renderer: true` 时必须实际完成 LibreOffice 页面渲染；渲染器不可用即失败。

`execute` 验证通过后才能生成报告；报告生成后必须再通过 `report` 验证。
