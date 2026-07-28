run_module <- function(config, context) {
  started_at <- utc_now()
  parameters <- module_parameters(config, "linear-regression")
  outcome <- as.character(parameters$outcome %||% "")
  predictors <- unique(as.character(parameters$predictors %||% character()))
  categorical <- unique(as.character(parameters$categorical %||% character()))
  robust_se <- isTRUE(parameters$robust_se)
  robust_se_type <- toupper(as.character(parameters$robust_se_type %||% "HC3"))
  confidence_level <- as.numeric(parameters$confidence_level %||% .95)
  if (!nzchar(outcome) || !length(predictors)) {
    stop("多元线性回归必须指定结局和至少一个预测变量。", call. = FALSE)
  }
  variables <- unique(c(outcome, predictors))
  assert_columns(context$data, variables, "linear-regression")
  subset <- analysis_subset(context$data, variables)
  data <- subset$data
  data[[outcome]] <- safe_numeric(data[[outcome]])
  for (variable in intersect(categorical, predictors)) data[[variable]] <- as.factor(data[[variable]])
  references <- parameters$reference_levels %||% config$variables$reference_levels %||% list()
  data <- apply_reference_levels(data, references)
  model_matrix <- stats::model.matrix(build_formula(outcome, predictors), data = data)
  parameter_count <- ncol(model_matrix)
  if (nrow(data) <= parameter_count + 5L) {
    stop("线性回归有效样本量不足以支持当前参数数量。", call. = FALSE)
  }

  model <- stats::lm(build_formula(outcome, predictors), data = data)
  summary_model <- summary(model)
  coefficient_matrix <- summary_model$coefficients
  confidence <- suppressMessages(stats::confint(model, level = confidence_level))
  inference_type <- "常规 OLS 标准误"
  if (robust_se) {
    if (robust_se_type != "HC3") stop("当前仅支持 HC3 稳健标准误。", call. = FALSE)
    design <- stats::model.matrix(model)
    leverage <- stats::hatvalues(model)
    residuals_for_vcov <- stats::residuals(model)
    bread <- tryCatch(solve(crossprod(design)), error = function(e) NULL)
    if (is.null(bread) || any(!is.finite(leverage)) || any(1 - leverage < 1e-10)) {
      stop("无法计算 HC3 稳健标准误：模型矩阵奇异或存在高杠杆观测。", call. = FALSE)
    }
    weighted_design <- design * (residuals_for_vcov / (1 - leverage))
    robust_vcov <- bread %*% crossprod(weighted_design) %*% bread
    robust_error <- sqrt(diag(robust_vcov))
    coefficient_matrix[, "Std. Error"] <- robust_error
    coefficient_matrix[, "t value"] <- stats::coef(model) / robust_error
    coefficient_matrix[, "Pr(>|t|)"] <- 2 * stats::pt(abs(coefficient_matrix[, "t value"]), df = stats::df.residual(model), lower.tail = FALSE)
    critical_value <- stats::qt((1 + confidence_level) / 2, df = stats::df.residual(model))
    confidence <- cbind(
      stats::coef(model) - critical_value * robust_error,
      stats::coef(model) + critical_value * robust_error
    )
    inference_type <- "HC3 异方差稳健标准误"
  }
  coefficients <- data.frame(
    term = rownames(coefficient_matrix),
    estimate = coefficient_matrix[, "Estimate"],
    std_error = coefficient_matrix[, "Std. Error"],
    statistic = coefficient_matrix[, "t value"],
    p_value = coefficient_matrix[, "Pr(>|t|)"],
    conf_low = confidence[, 1],
    conf_high = confidence[, 2],
    inference = inference_type,
    stringsAsFactors = FALSE,
    row.names = NULL
  )

  f_stat <- summary_model$fstatistic
  model_summary <- data.frame(
    n = stats::nobs(model),
    parameters = length(stats::coef(model)),
    r_squared = summary_model$r.squared,
    adjusted_r_squared = summary_model$adj.r.squared,
    residual_sd = summary_model$sigma,
    f_statistic = unname(f_stat[[1]]),
    df_model = unname(f_stat[[2]]),
    df_residual = unname(f_stat[[3]]),
    model_p_value = stats::pf(f_stat[[1]], f_stat[[2]], f_stat[[3]], lower.tail = FALSE),
    aic = stats::AIC(model),
    bic = stats::BIC(model),
    inference = inference_type,
    stringsAsFactors = FALSE
  )

  residuals <- stats::residuals(model)
  fitted <- stats::fitted(model)
  shapiro_p <- if (length(residuals) >= 3L && length(residuals) <= 5000L) stats::shapiro.test(residuals)$p.value else NA_real_
  bp_model <- stats::lm(I(residuals^2) ~ fitted)
  bp_stat <- length(residuals) * summary(bp_model)$r.squared
  bp_p <- stats::pchisq(bp_stat, df = 1L, lower.tail = FALSE)
  cook_threshold <- 4 / length(residuals)
  influential_n <- sum(stats::cooks.distance(model) > cook_threshold, na.rm = TRUE)
  alias_detected <- any(is.na(stats::coef(model)))

  vif_values <- numeric()
  design <- model_matrix[, colnames(model_matrix) != "(Intercept)", drop = FALSE]
  if (ncol(design) >= 2L && nrow(design) > ncol(design) + 2L) {
    vif_values <- vapply(seq_len(ncol(design)), function(index) {
      response <- design[, index]
      others <- design[, -index, drop = FALSE]
      if (stats::sd(response) == 0) return(Inf)
      r2 <- summary(stats::lm(response ~ others))$r.squared
      1 / max(1e-12, 1 - r2)
    }, numeric(1))
    names(vif_values) <- colnames(design)
  }
  max_vif <- if (length(vif_values)) max(vif_values, na.rm = TRUE) else NA_real_
  diagnostics_table <- data.frame(
    diagnostic = c("残差 Shapiro-Wilk", "简化 Breusch-Pagan", "最大 VIF", "Cook 距离超阈值数", "别名/奇异系数"),
    value = c(shapiro_p, bp_p, max_vif, influential_n, as.numeric(alias_detected)),
    rule = c("P<0.05 提示残差偏离正态", "P<0.05 提示异方差", ">5 需关注共线性", paste0("Cook D > ", signif(cook_threshold, 3)), "1 表示模型矩阵不可识别"),
    status = c(
      ifelse(is.na(shapiro_p), "not_assessed", ifelse(shapiro_p < .05, "warning", "pass")),
      ifelse(bp_p < .05, "warning", "pass"),
      ifelse(is.na(max_vif), "not_assessed", ifelse(max_vif > 5, "warning", "pass")),
      ifelse(influential_n > 0, "warning", "pass"),
      ifelse(alias_detected, "fail", "pass")
    ),
    stringsAsFactors = FALSE
  )

  warnings <- character()
  if (subset$n_excluded_missing > 0L) warnings <- c(warnings, paste0("因模型变量缺失排除 ", subset$n_excluded_missing, " 行。"))
  if (bp_p < .05 && !robust_se) warnings <- c(warnings, "残差存在异方差迹象；解释常规标准误时需谨慎。")
  if (robust_se) warnings <- c(warnings, "系数使用 HC3 异方差稳健标准误；点估计仍来自 OLS 模型。")
  if (is.finite(max_vif) && max_vif > 5) warnings <- c(warnings, "检测到较高方差膨胀因子。")
  if (influential_n > 0L) warnings <- c(warnings, paste0("检测到 ", influential_n, " 个潜在高影响观测；未自动删除。"))
  if (alias_detected) warnings <- c(warnings, "模型存在不可识别系数。")

  figure_source <- data.frame(
    observation_index = seq_along(fitted),
    observed_outcome = as.numeric(data[[outcome]]),
    fitted_value = as.numeric(fitted),
    residual = as.numeric(residuals),
    standardized_residual = as.numeric(stats::rstandard(model)),
    leverage = as.numeric(stats::hatvalues(model)),
    cooks_distance = as.numeric(stats::cooks.distance(model)),
    stringsAsFactors = FALSE
  )
  source_data_path <- write_figure_source_data(
    context, "linear_diagnostics", figure_source
  )
  plot_linear_diagnostics <- function() {
    old_par <- graphics::par(mfrow = c(2, 2), mar = c(4, 4, 3, 1))
    on.exit(graphics::par(old_par), add = TRUE)
    try(graphics::plot(model), silent = TRUE)
  }
  figure_exports <- export_r_figure(
    config,
    context,
    "01_线性回归诊断图",
    plot_linear_diagnostics,
    width_mm = 183,
    height_mm = 142
  )
  model_path <- file.path(context$module_output_dir, "01_线性回归模型.rds")
  saveRDS(model, model_path)

  tables <- list(
    write_result_table(context, "linear-regression", "01_线性回归系数", "多元线性回归系数", coefficients, c(paste0("所有回归项统一报告估计值、", confidence_level * 100, "% 置信区间与 P 值；推断类型见 inference 列。"))),
    write_result_table(context, "linear-regression", "02_线性回归模型摘要", "多元线性回归模型摘要", model_summary),
    write_result_table(context, "linear-regression", "03_线性回归诊断", "多元线性回归诊断", diagnostics_table,
      c("异常点和影响点只标记，不自动删除。"))
  )
  new_module_result(
    "linear-regression", "multiple-linear-regression", started_at,
    tables = tables,
    figures = list(new_figure_object(
      figure_id = "linear_diagnostics",
      title = "线性回归诊断图",
      exports = figure_exports,
      source_data_path = source_data_path,
      conclusion = "使用残差、杠杆值和 Cook 距离审计线性回归拟合；诊断结果不自动触发病例删除。",
      evidence_role = "model_diagnostic",
      statistics = list(
        n_definition = paste0(subset$n_complete, " 个完整案例"),
        biological_replicates = paste0(subset$n_complete, " 个独立分析单位"),
        technical_replicates = "不适用",
        center_statistic = "模型拟合值、残差、杠杆值与 Cook 距离",
        interval = "不适用；诊断图不展示区间估计",
        test = "多元线性回归诊断",
        multiple_comparison_correction = "不适用"
      ),
      source_module = "linear-regression"
    )),
    model_objects = list(list(
      object_id = "linear_model",
      path = relative_path(model_path, context$run_dir),
      source_module = "linear-regression"
    )),
    diagnostics = lapply(seq_len(nrow(diagnostics_table)), function(i) as.list(diagnostics_table[i, ])),
    warnings = unique(warnings),
    limitations = c("观察性回归系数不能自动解释为因果效应。", "当前版本使用完整案例拟合，不执行自动插补。"),
    narrative = c(paste0("以 ", outcome, " 为结局，纳入 ", length(predictors), " 个预测变量；", inference_type, "。")),
    sample = list(
      n_input = subset$n_input,
      n_complete = subset$n_complete,
      n_excluded_missing = subset$n_excluded_missing,
      parameters = parameter_count
    ),
    random_seed = context$random_seed
  )
}
