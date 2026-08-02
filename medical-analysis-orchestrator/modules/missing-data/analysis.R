run_module <- function(config, context) {
  started_at <- utc_now()
  parameters <- module_parameters(config, "missing-data")
  variables <- unique(as.character(parameters$variables %||% character()))
  method <- tolower(as.character(parameters$method %||% "audit"))
  imputations <- as.integer(parameters$imputations %||% 5L)
  iterations <- as.integer(parameters$iterations %||% 10L)
  minimum_complete_n <- as.integer(parameters$minimum_complete_n %||% 20L)
  if (!length(variables)) stop("缺失数据模块必须指定至少一个变量。", call. = FALSE)
  if (!method %in% c("audit", "mice")) stop("缺失数据方法仅支持 audit 或 mice。", call. = FALSE)
  if (imputations < 2L || imputations > 100L) stop("多重插补次数必须在 2 到 100 之间。", call. = FALSE)
  if (iterations < 1L || iterations > 100L) stop("多重插补迭代次数必须在 1 到 100 之间。", call. = FALSE)
  assert_columns(context$data, variables, "missing-data")
  data <- context$data[, variables, drop = FALSE]
  missing_n <- vapply(data, function(x) sum(is.na(x)), integer(1))
  missing_table <- data.frame(
    variable = variables,
    label = vapply(variables, function(x) configured_label(config, x), character(1)),
    n_total = nrow(data),
    n_missing = as.integer(missing_n),
    missing_percent = 100 * missing_n / max(1L, nrow(data)),
    n_observed = nrow(data) - missing_n,
    stringsAsFactors = FALSE
  )
  complete_rows <- sum(stats::complete.cases(data))
  any_missing <- any(missing_n > 0L)
  warnings <- character()
  imputation_table <- data.frame(
    variable = character(), method = character(), imputations = integer(),
    iterations = integer(), predictor_count = integer(), stringsAsFactors = FALSE
  )
  model_objects <- list()
  imputation_object <- NULL
  if (method == "mice") {
    if (!any_missing) {
      warnings <- c(warnings, "指定变量不存在缺失值，因此未执行多重插补。")
    } else {
      if (nrow(data) < minimum_complete_n) {
        stop("样本量不足以执行已确认的多重插补。", call. = FALSE)
      }
      constant <- vapply(data, function(x) length(unique(x[!is.na(x)])) < 2L, logical(1))
      if (any(constant & missing_n > 0L)) {
        stop("存在缺失且无可识别变异的变量，不能自动插补：", paste(names(data)[constant & missing_n > 0L], collapse = ", "), call. = FALSE)
      }
      imputation_object <- mice::mice(
        data,
        m = imputations,
        maxit = iterations,
        seed = context$random_seed,
        printFlag = FALSE,
        remove.constant = TRUE,
        remove.collinear = FALSE
      )
      methods <- imputation_object$method
      predictor_count <- rowSums(imputation_object$predictorMatrix != 0)
      imputed_variables <- names(methods)[nzchar(methods)]
      imputation_table <- data.frame(
        variable = imputed_variables,
        method = unname(methods[imputed_variables]),
        imputations = imputations,
        iterations = iterations,
        predictor_count = as.integer(predictor_count[imputed_variables]),
        stringsAsFactors = FALSE
      )
      model_path <- file.path(context$module_output_dir, "01_多重插补对象.rds")
      saveRDS(imputation_object, model_path)
      model_objects <- list(list(
        object_id = "multiple_imputation",
        path = relative_path(model_path, context$run_dir),
        source_module = "missing-data"
      ))
    }
  }

  source_data_path <- write_figure_source_data(
    context, "missingness_proportion", missing_table
  )
  plot_missingness <- function() {
    ordering <- order(missing_table$missing_percent, decreasing = TRUE)
    graphics::barplot(
      missing_table$missing_percent[ordering],
      names.arg = missing_table$variable[ordering],
      las = 2, col = "grey75", border = "black",
      ylab = "缺失比例（%）", main = "变量缺失比例"
    )
  }
  figure_exports <- export_r_figure(
    config, context, "01_变量缺失比例图", plot_missingness,
    width_mm = 183, height_mm = 120
  )
  tables <- list(
    write_result_table(
      context, "missing-data", "01_缺失数据概况", "缺失数据概况",
      missing_table,
      c("缺失比例仅描述数据可用性，不据此自动判定 MCAR、MAR 或 MNAR。")
    ),
    write_result_table(
      context, "missing-data", "02_多重插补方法", "多重插补方法",
      imputation_table,
      c("插补模型由 mice 按变量类型初始化；正式推断必须在各插补数据集分别拟合并按 Rubin 规则合并。")
    )
  )
  diagnostics <- list(
    list(
      diagnostic = "完整案例比例",
      value = complete_rows / max(1L, nrow(data)),
      rule = "信息性指标；不以固定阈值自动选择完整案例或插补",
      status = "informational"
    ),
    list(
      diagnostic = "插补执行状态",
      value = if (is.null(imputation_object)) 0 else 1,
      rule = if (method == "mice" && any_missing) "1 表示已生成多重插补对象" else "当前方案无需生成插补对象",
      status = if (method == "mice" && any_missing && is.null(imputation_object)) "fail" else "pass"
    )
  )
  new_module_result(
    "missing-data",
    if (method == "mice") "multiple-imputation-by-chained-equations" else "missingness-audit",
    started_at,
    tables = tables,
    figures = list(new_figure_object(
      figure_id = "missingness_proportion",
      title = "变量缺失比例图",
      exports = figure_exports,
      source_data_path = source_data_path,
      conclusion = "图形展示已确认变量的缺失比例，不对缺失机制作自动判定。",
      evidence_role = "data_quality_diagnostic",
      statistics = list(
        n_definition = paste0(nrow(data), " 行输入记录"),
        biological_replicates = "按输入分析单位计数",
        technical_replicates = "不适用",
        center_statistic = "变量缺失比例",
        interval = "不适用",
        test = "未执行假设检验",
        multiple_comparison_correction = "不适用"
      ),
      source_module = "missing-data"
    )),
    model_objects = model_objects,
    diagnostics = diagnostics,
    warnings = warnings,
    limitations = c(
      "缺失机制不能仅由观测数据自动确认。",
      "本模块生成插补对象但不把单个插补数据集冒充为完整推断；下游模型必须显式实施并合并估计。"
    ),
    narrative = c(paste0("审计 ", length(variables), " 个变量；完整案例 ", complete_rows, "/", nrow(data), "。")),
    sample = list(
      n_input = nrow(data), n_complete = complete_rows,
      n_incomplete = nrow(data) - complete_rows,
      variables = length(variables), imputations = if (is.null(imputation_object)) 0 else imputations
    ),
    random_seed = context$random_seed
  )
}
