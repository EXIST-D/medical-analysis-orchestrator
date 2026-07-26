run_module <- function(config, context) {
  started_at <- utc_now()
  parameters <- module_parameters(config, "descriptive")
  data <- context$data

  continuous <- unique(as.character(parameters$continuous %||% character()))
  categorical <- unique(as.character(parameters$categorical %||% character()))
  if (!length(continuous)) {
    continuous <- names(data)[vapply(data, is.numeric, logical(1))]
    continuous <- continuous[vapply(data[continuous], function(x) length(unique(x[!is.na(x)])) > 5L, logical(1))]
  }
  if (!length(categorical)) {
    categorical <- setdiff(
      names(data)[vapply(data, function(x) {
        is.factor(x) || is.character(x) || is.logical(x) ||
          length(unique(x[!is.na(x)])) <= 5L
      }, logical(1))],
      continuous
    )
  }
  assert_columns(data, c(continuous, categorical), "descriptive")

  continuous_rows <- lapply(continuous, function(variable) {
    x <- safe_numeric(data[[variable]])
    valid <- x[is.finite(x)]
    quantiles <- if (length(valid)) stats::quantile(valid, c(0.25, 0.5, 0.75), names = FALSE) else rep(NA_real_, 3)
    data.frame(
      variable = variable,
      label = configured_label(config, variable),
      n = length(valid),
      missing_n = sum(!is.finite(x)),
      mean = if (length(valid)) mean(valid) else NA_real_,
      sd = if (length(valid) > 1L) stats::sd(valid) else NA_real_,
      median = quantiles[[2]],
      q1 = quantiles[[1]],
      q3 = quantiles[[3]],
      min = if (length(valid)) min(valid) else NA_real_,
      max = if (length(valid)) max(valid) else NA_real_,
      skewness = safe_skewness(valid),
      stringsAsFactors = FALSE
    )
  })
  continuous_table <- if (length(continuous_rows)) do.call(rbind, continuous_rows) else data.frame(
    variable = character(), label = character(), n = integer(), missing_n = integer(),
    mean = numeric(), sd = numeric(), median = numeric(), q1 = numeric(), q3 = numeric(),
    min = numeric(), max = numeric(), skewness = numeric()
  )

  threshold <- as.integer(config$reporting$small_cell_threshold %||% 5L)
  suppress_small <- isTRUE(config$reporting$suppress_small_cells)
  categorical_rows <- list()
  for (variable in categorical) {
    values <- as.character(data[[variable]])
    missing_n <- sum(is.na(values) | !nzchar(values))
    observed <- values[!is.na(values) & nzchar(values)]
    counts <- sort(table(observed, useNA = "no"), decreasing = TRUE)
    if (!length(counts)) next
    for (level in names(counts)) {
      count <- as.integer(counts[[level]])
      suppressed <- suppress_small && count > 0L && count < threshold
      categorical_rows[[length(categorical_rows) + 1L]] <- data.frame(
        variable = variable,
        label = configured_label(config, variable),
        level = level,
        n = if (suppressed) NA_integer_ else count,
        n_display = if (suppressed) paste0("<", threshold) else as.character(count),
        pct_valid = if (suppressed) NA_real_ else 100 * count / length(observed),
        missing_n = missing_n,
        stringsAsFactors = FALSE
      )
    }
  }
  categorical_table <- if (length(categorical_rows)) do.call(rbind, categorical_rows) else data.frame(
    variable = character(), label = character(), level = character(), n = integer(),
    n_display = character(), pct_valid = numeric(), missing_n = integer()
  )

  tables <- list(
    write_result_table(
      context, "descriptive", "01_连续变量描述性统计",
      "连续变量描述性统计", continuous_table,
      c("连续变量报告均值、标准差、中位数、四分位数和范围。")
    ),
    write_result_table(
      context, "descriptive", "02_分类变量描述性统计",
      "分类变量描述性统计", categorical_table,
      c(if (suppress_small) paste0("频数小于 ", threshold, " 的单元格已抑制。") else "未启用小单元格抑制。")
    )
  )
  new_module_result(
    "descriptive", "descriptive-statistics", started_at,
    tables = tables,
    limitations = c("描述性统计不能控制混杂或支持因果解释。"),
    narrative = c(
      paste0("本模块汇总 ", length(continuous), " 个连续变量和 ", length(categorical), " 个分类变量。")
    ),
    sample = list(n_input = nrow(data)),
    random_seed = context$random_seed
  )
}
