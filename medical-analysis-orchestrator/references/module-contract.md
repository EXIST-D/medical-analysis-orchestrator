# 统计模块统一接口

模块位于 `modules/<module-id>/`，并在 `modules/registry.yml` 注册。注册表只负责完整列举模块和固定输出顺序；方法、依赖与参数契约以各模块的 `module.yml` 为准。

## module.yml

必须声明：

```yaml
schema_version: "1.1"
id: "example"
name_zh: "示例方法"
status: "planned"
version: "0.1.0"
output_order: 20
output_dir: "20_示例方法"
methods: []
entrypoint: "analysis.R"
required_packages: []
optional_packages: []
required_config: []
outputs:
  tables: []
  figures: []
  reporting_evidence: []
  model_objects: []
```

状态：

- `planned`：仅设计，不执行。
- `scaffold`：接口未完整验证，不执行正式分析。
- `ready`：实现、诊断、输出验证和自动化测试均通过。
- `disabled`：因统计、安全或兼容性问题禁用。

`planned` 模块可以保留尚不存在的入口文件名作为接口占位；只有升级为 `ready` 时，入口文件、自动化测试和输出验证才必须同时存在。

## R 入口

`ready` 模块必须定义：

```r
run_module <- function(config, context) {
  # 返回统一结果对象
}
```

`context` 提供 `run_id`、`run_dir`、只读清洁数据、输入与清洁副本指纹、随机种子、模块输出目录、Skill 根目录和日志目录。

模块不得安装包、修改原始数据或直接生成最终 Word 报告。模块只负责统计计算、诊断、图形、模型对象和结构化表格。模块可选返回 `reporting_evidence`，为已登记表或图提供可追溯的结果陈述与谨慎解释；未提供时由报告器只基于已登记的结果文件生成保守说明。

## 最低质量门槛

1. 明确支持的设计、结局类型、变量要求和不支持场景。
2. 校验变量存在、类型、样本量、事件数、识别性和收敛。
3. 记录完整案例数、缺失排除数、警告和限制。
4. 所有随机过程使用配置种子。
5. 表格同时输出 CSV 与三线表 XLSX。
6. 模型保存为 RDS；图形必须使用共享 R 图形接口，登记 Source Data、R 导出文件、证据角色、结论和统计元数据。
7. 至少测试成功路径、应拒绝路径和输出契约。
8. 失败时停止该运行，不能把部分结果包装成成功报告。

图形模块必须调用：

```text
write_figure_source_data
export_r_figure
new_figure_object
```

不得由 Python 重绘统计图，不得只返回一个缺少 Source Data 和统计说明的图片路径。
