run_module <- function(config, context) {
  started_at <- utc_now()
  parameters <- module_parameters(config, "correlation")
  variables <- unique(as.character(parameters$variables %||% character()))
  method <- tolower(as.character(parameters$method %||% "spearman"))
  adjust_method <- as.character(parameters$adjust_method %||% "holm")
  confidence_level <- as.numeric(parameters$confidence_level %||% .95)
  if (!method %in% c("pearson", "spearman", "kendall")) {
    stop("相关方法必须是 pearson、spearman 或 kendall。", call. = FALSE)
  }
  if (length(variables) < 2L) stop("相关性分析至少需要 2 个变量。", call. = FALSE)
  assert_columns(context$data, variables, "correlation")
  numeric_data <- as.data.frame(lapply(context$data[variables], safe_numeric), check.names = FALSE)

  coefficient_matrix <- stats::cor(numeric_data, use = "pairwise.complete.obs", method = method)
  matrix_table <- data.frame(variable = rownames(coefficient_matrix), coefficient_matrix, check.names = FALSE)
  effective_n_matrix <- outer(
    variables,
    variables,
    Vectorize(function(first, second) {
      sum(stats::complete.cases(numeric_data[, c(first, second), drop = FALSE]))
    })
  )
  dimnames(effective_n_matrix) <- list(variables, variables)
  effective_n_table <- data.frame(
    variable = rownames(effective_n_matrix), effective_n_matrix, check.names = FALSE
  )

  pair_rows <- list()
  combinations <- utils::combn(variables, 2L, simplify = FALSE)
  warnings <- character()
  for (pair in combinations) {
    frame <- numeric_data[, pair, drop = FALSE]
    frame <- frame[stats::complete.cases(frame), , drop = FALSE]
    if (nrow(frame) < 3L || stats::sd(frame[[1]]) == 0 || stats::sd(frame[[2]]) == 0) {
      warnings <- c(warnings, paste0(pair[[1]], " 与 ", pair[[2]], " 有效样本不足或存在常量。"))
      next
    }
    test <- suppressWarnings(stats::cor.test(frame[[1]], frame[[2]], method = method, exact = FALSE, conf.level = confidence_level))
    confidence <- if (!is.null(test$conf.int)) unname(test$conf.int) else c(NA_real_, NA_real_)
    pair_rows[[length(pair_rows) + 1L]] <- data.frame(
      variable_1 = pair[[1]],
      variable_2 = pair[[2]],
      n = nrow(frame),
      method = method,
      coefficient = unname(test$estimate),
      conf_low = confidence[[1]],
      conf_high = confidence[[2]],
      statistic = unname(test$statistic),
      p_value = test$p.value,
      stringsAsFactors = FALSE
    )
  }
  details <- if (length(pair_rows)) do.call(rbind, pair_rows) else data.frame(
    variable_1 = character(), variable_2 = character(), n = integer(), method = character(),
    coefficient = numeric(), conf_low = numeric(), conf_high = numeric(),
    statistic = numeric(), p_value = numeric()
  )
  details$p_adjusted <- if (nrow(details)) stats::p.adjust(details$p_value, method = adjust_method) else numeric()

  tables <- list(
    write_result_table(
      context, "correlation", "01_相关系数矩阵",
      paste0(toupper(substring(method, 1, 1)), substring(method, 2), " 相关系数矩阵"),
      matrix_table,
      c("矩阵按变量对使用可用案例计算；各变量对有效样本量可能不同。")
    ),
    write_result_table(
      context, "correlation", "02_相关有效样本量矩阵",
      "相关分析的变量对有效样本量矩阵", effective_n_table,
      c("每个单元格为对应变量对的成对完整案例数；应与相关系数矩阵一并解读。")
    ),
    write_result_table(
      context, "correlation", "03_相关性检验明细",
      "相关性检验明细", details,
      c(paste0("P 值使用 ", adjust_method, " 方法在本相关分析族内校正；可用时报告 ", confidence_level * 100, "% 置信区间。"))
    )
  )
  new_module_result(
    "correlation", paste0(method, "-correlation"), started_at,
    tables = tables,
    warnings = unique(warnings),
    limitations = c("相关关系不等于因果关系；成对完整案例可能导致各相关系数使用不同样本。"),
    narrative = c(paste0("对 ", length(variables), " 个变量执行 ", method, " 相关分析。")),
    sample = list(n_input = nrow(context$data), variables = as.list(variables)),
    random_seed = context$random_seed
  )
}
