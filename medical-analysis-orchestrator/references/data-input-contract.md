# 数据输入契约

## 支持范围

首版读取 CSV、TSV、TXT、XLSX、XLS、SPSS SAV、Stata DTA、SAS7BDAT、XPT、JSON、JSONL、Parquet 和 Feather。`.dat` 按分隔文本探测；无法可靠识别分隔符时只登记文件，不猜测字段结构。

每次运行必须：

1. 记录文件名、扩展名、字节数、修改时间和 SHA-256。
2. 保持原始文件只读，不在原位置写回。
3. 多文件默认分别探查，不自动合并。
4. Excel 默认逐工作表盘点；正式分析必须确认工作表。
5. SPSS、Stata、SAS 的变量标签和值标签写入变量字典，但不自动改变编码。
6. 输出只含聚合画像；不得把姓名、病历号、证件号、电话、地址或自由文本样例写入日志。

## 数据集选择

正式执行时，`input.path` 必须指向单个文件，或同时指定 `input.dataset`。一个运行只能有一个主分析数据集。多文件合并必须在 `data_handling.merge_plan` 中明确：

- 主表和从表；
- 连接键；
- 连接类型；
- 键的基数；
- 重复匹配处理；
- 合并后的预期行数；
- 用户确认记录。

## 标准输出

`inspect` 阶段生成：

```text
data_inventory.json
data_profile.json
data_profile.csv
01_数据整理/01_变量字典.xlsx
01_数据整理/02_数据质量报告.xlsx
01_数据整理/03_清洗操作候选.csv
manifest.json
```

`execute` 前的数据准备阶段另生成：

```text
01_数据整理/04_数据清洗日志.csv
01_数据整理/05_清洁分析数据.csv
01_数据整理/06_清洁分析数据.xlsx
```

CSV 是机器可读主数据；XLSX 是便于人工核查的副本。
