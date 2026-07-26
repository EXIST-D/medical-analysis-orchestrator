run_module <- function(config, context) {
  started_at <- utc_now()
  parameters <- module_parameters(config, "group-comparison")
  data <- context$data
  group_variable <- as.character(parameters$group %||% "")
  continuous <- unique(as.character(parameters$continuous %||% character()))
  categorical <- unique(as.character(parameters$categorical %||% character()))
  method_requested <- tolower(as.character(parameters$continuous_method %||% "auto"))
  if (!nzchar(group_variable)) stop("单因素分析必须指定分组变量。", call. = FALSE)
  assert_columns(data, c(group_variable, continuous, categorical), "group-comparison")
  group <- as.factor(data[[group_variable]])
  if (nlevels(droplevels(group)) < 2L) stop("分组变量有效水平少于 2 个。", call. = FALSE)

  continuous_results <- list()
  warnings <- character()
  for (variable in continuous) {
    frame <- data.frame(value = safe_numeric(data[[variable]]), group = group)
    frame <- frame[stats::complete.cases(frame), , drop = FALSE]
    frame$group <- droplevels(frame$group)
    k <- nlevels(frame$group)
    if (nrow(frame) < 6L || k < 2L) {
      warnings <- c(warnings, paste0(variable, " 有效样本不足，未执行组间检验。"))
      next
    }
    group_summary <- vapply(
      split(frame$value, frame$group),
      function(x) sprintf("%.3f ± %.3f；中位数 %.3f [%.3f, %.3f]", mean(x), stats::sd(x), stats::median(x), stats::quantile(x, .25), stats::quantile(x, .75)),
      character(1)
    )
    summary_text <- paste(paste(names(group_summary), group_summary, sep = ": "), collapse = " | ")
    if (k == 2L && method_requested %in% c("mann-whitney", "wilcoxon", "nonparametric")) {
      test <- stats::wilcox.test(value ~ group, data = frame, exact = FALSE, conf.int = FALSE)
      method <- "Mann-Whitney U 检验"
      statistic <- unname(test$statistic)
      estimate <- NA_real_
      conf_low <- NA_real_
      conf_high <- NA_real_
      p_value <- test$p.value
    } else if (k == 2L) {
      test <- stats::t.test(value ~ group, data = frame, var.equal = FALSE)
      method <- "Welch t 检验"
      statistic <- unname(test$statistic)
      estimate <- diff(unname(test$estimate))
      conf_low <- unname(test$conf.int[[1]])
      conf_high <- unname(test$conf.int[[2]])
      p_value <- test$p.value
    } else if (method_requested %in% c("kruskal-wallis", "kruskal", "nonparametric")) {
      test <- stats::kruskal.test(value ~ group, data = frame)
      method <- "Kruskal-Wallis 检验"
      statistic <- unname(test$statistic)
      estimate <- NA_real_
      conf_low <- NA_real_
      conf_high <- NA_real_
      p_value <- test$p.value
    } else {
      test <- stats::oneway.test(value ~ group, data = frame, var.equal = FALSE)
      method <- "Welch ANOVA"
      statistic <- unname(test$statistic)
      estimate <- NA_real_
      conf_low <- NA_real_
      conf_high <- NA_real_
      p_value <- test$p.value
    }
    continuous_results[[length(continuous_results) + 1L]] <- data.frame(
      variable = variable,
      label = configured_label(config, variable),
      n = nrow(frame),
      groups = k,
      group_summary = summary_text,
      method = method,
      statistic = statistic,
      estimate = estimate,
      conf_low = conf_low,
      conf_high = conf_high,
      p_value = p_value,
      stringsAsFactors = FALSE
    )
  }
  continuous_table <- if (length(continuous_results)) do.call(rbind, continuous_results) else data.frame(
    variable = character(), label = character(), n = integer(), groups = integer(),
    group_summary = character(), method = character(), statistic = numeric(),
    estimate = numeric(), conf_low = numeric(), conf_high = numeric(), p_value = numeric()
  )
  if (nrow(continuous_table)) {
    continuous_table$p_adjusted <- stats::p.adjust(
      continuous_table$p_value,
      method = as.character(config$data_handling$multiple_testing$method %||% "holm")
    )
  } else {
    continuous_table$p_adjusted <- numeric()
  }

  categorical_results <- list()
  for (variable in categorical) {
    frame <- data.frame(value = as.factor(data[[variable]]), group = group)
    frame <- frame[stats::complete.cases(frame), , drop = FALSE]
    frame$value <- droplevels(frame$value)
    frame$group <- droplevels(frame$group)
    contingency <- table(frame$value, frame$group)
    if (nrow(contingency) < 2L || ncol(contingency) < 2L) {
      warnings <- c(warnings, paste0(variable, " 的列联表维度不足，未执行检验。"))
      next
    }
    chi <- suppressWarnings(stats::chisq.test(contingency, correct = FALSE))
    sparse <- any(chi$expected < 5)
    if (sparse) {
      exact <- tryCatch(
        stats::fisher.test(contingency),
        error = function(e) stats::fisher.test(contingency, simulate.p.value = TRUE, B = 5000)
      )
      method <- if (is.null(exact$simulate.p.value) || !exact$simulate.p.value) "Fisher 精确检验" else "Fisher Monte Carlo 检验"
      statistic <- NA_real_
      p_value <- exact$p.value
    } else {
      method <- "Pearson 卡方检验"
      statistic <- unname(chi$statistic)
      p_value <- chi$p.value
    }
    total <- sum(contingency)
    cramers_v <- sqrt(unname(chi$statistic) / (total * min(nrow(contingency) - 1L, ncol(contingency) - 1L)))
    categorical_results[[length(categorical_results) + 1L]] <- data.frame(
      variable = variable,
      label = configured_label(config, variable),
      n = total,
      rows = nrow(contingency),
      columns = ncol(contingency),
      method = method,
      statistic = statistic,
      cramers_v = cramers_v,
      p_value = p_value,
      sparse_expected_cells = sum(chi$expected < 5),
      stringsAsFactors = FALSE
    )
  }
  categorical_table <- if (length(categorical_results)) do.call(rbind, categorical_results) else data.frame(
    variable = character(), label = character(), n = integer(), rows = integer(),
    columns = integer(), method = character(), statistic = numeric(),
    cramers_v = numeric(), p_value = numeric(), sparse_expected_cells = integer()
  )
  if (nrow(categorical_table)) {
    categorical_table$p_adjusted <- stats::p.adjust(
      categorical_table$p_value,
      method = as.character(config$data_handling$multiple_testing$method %||% "holm")
    )
  } else {
    categorical_table$p_adjusted <- numeric()
  }

  tables <- list(
    write_result_table(
      context, "group-comparison", "01_连续变量组间比较",
      "连续变量单因素组间比较", continuous_table,
      c("自动模式默认使用对方差不齐更稳健的 Welch 方法；非参数方法必须在方案中明确指定。")
    ),
    write_result_table(
      context, "group-comparison", "02_分类变量组间比较",
      "分类变量单因素组间比较", categorical_table,
      c("期望频数不足时改用 Fisher 精确检验或 Monte Carlo 近似。")
    )
  )
  new_module_result(
    "group-comparison", "univariate-group-comparison", started_at,
    tables = tables,
    warnings = unique(warnings),
    limitations = c("单因素分析未控制潜在混杂，不能替代多变量模型。"),
    narrative = c(
      paste0("以 ", group_variable, " 为分组变量完成已确认的单因素比较。")
    ),
    sample = list(n_input = nrow(data), group_variable = group_variable),
    random_seed = context$random_seed
  )
}
