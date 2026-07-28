# 统一结果对象

每个 R 模块返回以下结构：

```text
schema_version
module_id
method_id
status
started_at_utc
completed_at_utc
sample
tables
figures
model_objects
diagnostics
warnings
limitations
narrative
session_metadata
```

`status` 只能是 `completed`、`completed_with_warnings`、`skipped` 或 `failed`。

每个表对象至少包含：

```text
table_id
title
csv_path
xlsx_path
n_rows
n_columns
columns
footnotes
source_module
```

每个诊断对象至少包含 `diagnostic`、`value`、`rule` 和 `status`，可选包含 `message`。`status` 只能使用 `pass`、`warning`、`fail`、`not_assessed` 或 `informational`。存在 `warning` 或 `fail` 时，模块必须在 `warnings` 或 `limitations` 中给出可供报告器使用的解释；诊断失败时不得生成无条件肯定结论。`informational` 只用于没有方向性阈值的描述性性能指标，不能伪装为通过诊断。

每个图形对象至少包含：

```text
figure_id
title
path
preview_path
generated_by
exports
source_data_path
conclusion
evidence_role
statistics
source_module
```

`generated_by` 必须为 `R`。`exports` 登记格式、路径、物理尺寸、DPI 和矢量文字可编辑性；`statistics` 遵循 [R 图形证据契约](r-figure-contract.md)。

统一对象分别保存为：

```text
analysis_results.rds
analysis_results.json
```

JSON 只保存聚合元数据和结果文件索引，不保存患者级数据或完整模型对象。报告器只读取该对象及其登记的表格，不重新计算统计量。
