run_module <- function(config, context) {
  started_at <- utc_now()
  parameters <- module_parameters(config, "logistic-regression")
  outcome <- as.character(parameters$outcome %||% "")
  event_level <- as.character(parameters$event_level %||% "")
  predictors <- unique(as.character(parameters$predictors %||% character()))
  categorical <- unique(as.character(parameters$categorical %||% character()))
  if (!nzchar(outcome) || !nzchar(event_level) || !length(predictors)) {
    stop("Logistic 回归必须指定结局、事件水平和至少一个预测变量。", call. = FALSE)
  }
  variables <- unique(c(outcome, predictors))
  assert_columns(context$data, variables, "logistic-regression")
  subset <- analysis_subset(context$data, variables)
  data <- subset$data
  observed_levels <- unique(as.character(data[[outcome]]))
  if (length(observed_levels) != 2L || !event_level %in% observed_levels) {
    stop("Logistic 结局必须恰有两个有效水平，且事件水平必须存在。", call. = FALSE)
  }
  data$.analysis_event <- as.integer(as.character(data[[outcome]]) == event_level)
  for (variable in intersect(categorical, predictors)) data[[variable]] <- as.factor(data[[variable]])
  references <- parameters$reference_levels %||% config$variables$reference_levels %||% list()
  data <- apply_reference_levels(data, references)

  formula <- build_formula(".analysis_event", predictors)
  model_matrix <- stats::model.matrix(formula, data = data)
  parameter_count <- ncol(model_matrix)
  events <- sum(data$.analysis_event == 1L)
  non_events <- sum(data$.analysis_event == 0L)
  if (events == 0L || non_events == 0L) stop("有效分析样本中缺少事件或非事件。", call. = FALSE)
  if (nrow(data) <= parameter_count + 5L) stop("Logistic 回归有效样本量不足以支持当前参数数量。", call. = FALSE)

  model <- stats::glm(formula, data = data, family = stats::binomial())
  summary_model <- summary(model)
  coefficient_matrix <- summary_model$coefficients
  confidence <- suppressWarnings(stats::confint.default(model))
  coefficients <- data.frame(
    term = rownames(coefficient_matrix),
    estimate_log_odds = coefficient_matrix[, "Estimate"],
    std_error = coefficient_matrix[, "Std. Error"],
    statistic = coefficient_matrix[, "z value"],
    p_value = coefficient_matrix[, "Pr(>|z|)"],
    odds_ratio = exp(coefficient_matrix[, "Estimate"]),
    or_conf_low = exp(confidence[, 1]),
    or_conf_high = exp(confidence[, 2]),
    stringsAsFactors = FALSE,
    row.names = NULL
  )

  predicted <- stats::fitted(model)
  brier <- mean((data$.analysis_event - predicted)^2)
  auc <- {
    ranks <- rank(predicted, ties.method = "average")
    (sum(ranks[data$.analysis_event == 1L]) - events * (events + 1) / 2) / (events * non_events)
  }
  epv <- min(events, non_events) / max(1L, parameter_count - 1L)
  extreme_probability_n <- sum(predicted < 1e-6 | predicted > 1 - 1e-6)
  huge_coefficient_n <- sum(abs(stats::coef(model)) > 10, na.rm = TRUE)
  pseudo_r2 <- if (model$null.deviance > 0) 1 - model$deviance / model$null.deviance else NA_real_
  model_summary <- data.frame(
    n = nrow(data),
    events = events,
    non_events = non_events,
    parameters = parameter_count,
    events_per_parameter = epv,
    converged = isTRUE(model$converged),
    null_deviance = model$null.deviance,
    residual_deviance = model$deviance,
    mcfadden_like_r2 = pseudo_r2,
    aic = stats::AIC(model),
    bic = stats::BIC(model),
    brier_score = brier,
    auc = auc,
    stringsAsFactors = FALSE
  )
  diagnostics_table <- data.frame(
    diagnostic = c("模型收敛", "每参数较少类别事件数", "极端拟合概率数", "绝对值大于10的系数数", "AUC", "Brier分数"),
    value = c(as.numeric(model$converged), epv, extreme_probability_n, huge_coefficient_n, auc, brier),
    rule = c("1=收敛", "<10 提示模型不稳定风险", "大于0提示分离风险", "大于0提示分离或尺度问题", "越接近1区分度越高", "越接近0越好"),
    status = c(
      ifelse(model$converged, "pass", "fail"),
      ifelse(epv < 10, "warning", "pass"),
      ifelse(extreme_probability_n > 0, "warning", "pass"),
      ifelse(huge_coefficient_n > 0, "warning", "pass"),
      "informational",
      "informational"
    ),
    stringsAsFactors = FALSE
  )

  warnings <- character()
  if (subset$n_excluded_missing > 0L) warnings <- c(warnings, paste0("因模型变量缺失排除 ", subset$n_excluded_missing, " 行。"))
  if (!model$converged) warnings <- c(warnings, "模型未收敛。")
  if (epv < 10) warnings <- c(warnings, "较少类别事件数相对于参数数量偏低，估计可能不稳定。")
  if (extreme_probability_n > 0L || huge_coefficient_n > 0L) {
    warnings <- c(warnings, "检测到完全或准完全分离迹象；当前版本不自动切换惩罚 Logistic。")
  }

  ordering <- order(predicted, decreasing = TRUE)
  y_ordered <- data$.analysis_event[ordering]
  tpr <- c(0, cumsum(y_ordered == 1L) / events, 1)
  fpr <- c(0, cumsum(y_ordered == 0L) / non_events, 1)
  roc_source <- data.frame(
    point_index = seq_along(tpr),
    threshold = c(Inf, as.numeric(predicted[ordering]), -Inf),
    false_positive_rate = fpr,
    true_positive_rate = tpr,
    stringsAsFactors = FALSE
  )
  source_data_path <- write_figure_source_data(
    context, "roc_curve", roc_source
  )
  plot_roc <- function() {
    graphics::plot(
      roc_source$false_positive_rate,
      roc_source$true_positive_rate,
      type = "l", lwd = 2, col = "black",
      xlab = "1 - 特异度", ylab = "敏感度",
      main = paste0("ROC 曲线（AUC = ", sprintf("%.3f", auc), "）"),
      xlim = c(0, 1), ylim = c(0, 1), asp = 1
    )
    graphics::abline(0, 1, lty = 2, col = "grey50")
  }
  figure_exports <- export_r_figure(
    config,
    context,
    "01_ROC曲线",
    plot_roc,
    width_mm = 130,
    height_mm = 120
  )
  model_path <- file.path(context$module_output_dir, "01_Logistic回归模型.rds")
  saveRDS(model, model_path)

  tables <- list(
    write_result_table(context, "logistic-regression", "01_Logistic回归系数与OR", "Logistic 回归系数与 OR", coefficients),
    write_result_table(context, "logistic-regression", "02_Logistic回归模型摘要", "Logistic 回归模型摘要", model_summary),
    write_result_table(context, "logistic-regression", "03_Logistic回归诊断", "Logistic 回归诊断", diagnostics_table,
      c("AUC 和 Brier 分数均为建模样本内指标，不代表外部验证性能。"))
  )
  new_module_result(
    "logistic-regression", "binary-logistic-regression", started_at,
    tables = tables,
    figures = list(new_figure_object(
      figure_id = "roc_curve",
      title = "ROC 曲线",
      exports = figure_exports,
      source_data_path = source_data_path,
      conclusion = paste0(
        "ROC 曲线描述建模样本内的区分度（AUC = ",
        sprintf("%.3f", auc), "），不代表外部验证性能。"
      ),
      evidence_role = "internal_discrimination_diagnostic",
      statistics = list(
        n_definition = paste0(
          nrow(data), " 个完整案例，其中事件 ", events,
          " 个、非事件 ", non_events, " 个"
        ),
        biological_replicates = paste0(nrow(data), " 个独立分析单位"),
        technical_replicates = "不适用",
        center_statistic = "ROC 曲线下面积（AUC）",
        interval = "当前内部 AUC 未计算置信区间",
        test = "建模样本内 ROC 分析",
        multiple_comparison_correction = "不适用"
      ),
      source_module = "logistic-regression"
    )),
    model_objects = list(list(
      object_id = "logistic_model",
      path = relative_path(model_path, context$run_dir),
      source_module = "logistic-regression"
    )),
    diagnostics = lapply(seq_len(nrow(diagnostics_table)), function(i) as.list(diagnostics_table[i, ])),
    warnings = unique(warnings),
    limitations = c(
      "优势比不等同于风险比。",
      "当前性能指标来自建模样本内部，未进行交叉验证或外部验证。",
      "观察性关联不能自动解释为因果效应。"
    ),
    narrative = c(paste0("以 ", outcome, "=", event_level, " 为事件拟合二元 Logistic 回归。")),
    sample = list(
      n_input = subset$n_input,
      n_complete = subset$n_complete,
      n_excluded_missing = subset$n_excluded_missing,
      events = events,
      non_events = non_events,
      parameters = parameter_count
    ),
    random_seed = context$random_seed
  )
}
