# R 图形证据契约

本契约由 `medical-analysis-orchestrator` 自主定义，用于保证统计计算、图形、Source Data 和报告来自同一次 R 分析，不允许跨语言重绘导致数值或视觉语义漂移。

## 后端边界

- 统计图形必须由 R 生成，包括预览和正式导出。
- Python 可以编排、校验文件、嵌入 Word，但不得重新计算或重绘 R 图形。
- R 或所需包不可用时停止图形步骤并报告缺失项，不切换其他绘图后端。
- 图形脚本只消费本次运行的清洁分析副本或模块结果对象。

## 两种图形档位

### `analysis`

用于常规分析报告。默认输出 PNG，但仍必须登记 Source Data、结论角色和统计元数据。

### `manuscript`

用于论文或投稿材料。必须输出：

```text
PNG  预览和 Word 嵌入
SVG  可编辑矢量
PDF  可编辑矢量
TIFF 高分辨率栅格
CSV  图形 Source Data
```

投稿档位要求至少 300 dpi；默认 600 dpi。SVG/PDF 必须登记 `editable_text: true`。

## 图形对象

每张图至少登记：

```text
figure_id
title
generated_by = R
path
preview_path
exports
source_data_path
conclusion
evidence_role
statistics
source_module
```

`statistics` 至少包含：

```text
n_definition
biological_replicates
technical_replicates
center_statistic
interval
test
multiple_comparison_correction
```

没有适用内容时明确写“不适用”，不得留空或让报告器猜测。

## 图形设计规则

1. 先写一句图形结论，再确定图形和面板。
2. 每个面板只承担一个不可替代的证据角色。
3. 图形结论不得超过研究设计和统计模型支持的解释层级。
4. 不以颜色、坐标截断或选择性标注夸大效应。
5. 不把红色和绿色作为唯一区分手段。
6. 多面板图统一变量编码、颜色含义、单位和图例。
7. 图注同时说明样本定义、中心统计量、区间或误差、检验和多重校正。
8. 每个定量图必须能追溯到独立 Source Data 文件。
9. 小样本分组比较不能只给出均值柱状图；除非研究设计不允许，应同时显示原始观测或其等价分布信息。
10. 不使用双 Y 轴、饼图、三维图、彩虹/jet 色带，且不把无序分类水平用线连接。
11. 误差线必须明确 SD、SE、CI 或 IQR；显著性标记必须对应已确认的比较和多重校正策略，默认优先报告效应量与区间。

## R 模块实现

使用共享函数：

```r
write_figure_source_data(...)
export_r_figure(...)
new_figure_object(...)
```

模块不得自行调用 Python 绘图，也不得只写一个未登记来源的 PNG。复杂图形可以增加 R 包，但依赖必须写入 `module.yml`，由项目 Library 按需安装。

## 验证门

`validate_outputs.py` 检查：

- `generated_by` 是否为 `R`；
- Source Data 是否存在；
- 统计元数据是否完整；
- 导出格式是否与确认方案一致；
- 投稿档位是否包含 PNG、SVG、PDF、TIFF；
- SVG/PDF 是否登记可编辑文字；
- 所有路径是否属于同一运行目录并被 manifest 收录。

流水线还会生成 `90_最终报告/figure_plan.json` 和 `90_最终报告/figure_visual_qa.json`。后者读取既有 R 图像，检查实际像素、DPI、格式、路径和元数据，并可产生灰度复核副本；它不重新计算或重绘任何统计图。
