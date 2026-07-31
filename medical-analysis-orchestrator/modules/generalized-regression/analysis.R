coefficient_frame <- function(matrix, confidence_level, exponentiate = TRUE, label = "ratio") {
  critical <- stats::qnorm((1 + confidence_level) / 2)
  estimate <- matrix[, 1]
  standard_error <- matrix[, 2]
  statistic <- estimate / standard_error
  p_value <- 2 * stats::pnorm(abs(statistic), lower.tail = FALSE)
  lower <- estimate - critical * standard_error
  upper <- estimate + critical * standard_error
  data.frame(
    term = rownames(matrix), estimate = estimate, std_error = standard_error,
    statistic = statistic, p_value = p_value,
    effect_measure = label,
    effect = if (exponentiate) exp(estimate) else estimate,
    conf_low = if (exponentiate) exp(lower) else lower,
    conf_high = if (exponentiate) exp(upper) else upper,
    stringsAsFactors = FALSE, row.names = NULL
  )
}

run_module <- function(config, context) {
  started_at <- utc_now()
  parameters <- module_parameters(config, "generalized-regression")
  family_name <- tolower(as.character(parameters$family %||% ""))
  outcome <- as.character(parameters$outcome %||% "")
  predictors <- unique(as.character(parameters$predictors %||% character()))
  categorical <- unique(as.character(parameters$categorical %||% character()))
  reference_levels <- parameters$reference_levels %||% config$variables$reference_levels %||% list()
  outcome_reference <- as.character(parameters$outcome_reference %||% "")
  offset_variable <- as.character(parameters$offset %||% "")
  confidence_level <- as.numeric(parameters$confidence_level %||% .95)
  allowed <- c("ordinal", "multinomial", "poisson", "negative-binomial")
  if (!family_name %in% allowed) stop("广义回归 family 必须为 ordinal、multinomial、poisson 或 negative-binomial。", call. = FALSE)
  if (!nzchar(outcome) || !length(predictors)) stop("广义回归必须指定结局和至少一个预测变量。", call. = FALSE)
  variables <- unique(c(outcome, predictors, offset_variable))
  variables <- variables[nzchar(variables)]
  assert_columns(context$data, variables, "generalized-regression")
  subset <- analysis_subset(context$data, variables)
  data <- subset$data
  for (variable in intersect(categorical, predictors)) data[[variable]] <- as.factor(data[[variable]])
  data <- apply_reference_levels(data, reference_levels)
  formula <- build_formula(outcome, predictors)
  model_matrix <- stats::model.matrix(formula, data = data)
  parameter_count <- ncol(model_matrix)
  if (nrow(data) <= parameter_count + 10L) stop("有效样本量不足以支持当前广义回归参数数量。", call. = FALSE)
  diagnostics <- list()
  warnings <- character()
  coefficients <- data.frame()
  model <- NULL
  method_id <- ""
  model_summary <- data.frame()

  if (family_name == "ordinal") {
    data[[outcome]] <- ordered(data[[outcome]])
    if (nlevels(data[[outcome]]) < 3L) stop("有序 Logistic 结局至少需要三个有序水平。", call. = FALSE)
    level_counts <- table(data[[outcome]])
    if (any(level_counts < 10L)) warnings <- c(warnings, "有序结局至少一个等级少于 10 例，估计可能不稳定。")
    model <- MASS::polr(formula, data = data, Hess = TRUE, method = "logistic")
    coef_matrix <- summary(model)$coefficients
    coefficients <- coefficient_frame(coef_matrix, confidence_level, TRUE, "proportional_odds_ratio")
    coefficients$component <- ifelse(coefficients$term %in% names(stats::coef(model)), "predictor", "threshold")
    predictor_rows <- coefficients$component == "predictor"
    coefficients$effect[predictor_rows] <- exp(coefficients$estimate[predictor_rows])
    coefficients$effect[!predictor_rows] <- NA_real_
    coefficients$conf_low[!predictor_rows] <- NA_real_
    coefficients$conf_high[!predictor_rows] <- NA_real_
    method_id <- "ordinal-logistic"
    diagnostics <- list(list(
      diagnostic = "比例优势假设",
      value = NA_real_,
      rule = "当前实现不以单一自动检验判定；须结合累积 logits 与临床合理性审查",
      status = "not_assessed",
      message = "比例优势假设需人工和敏感性模型进一步确认。"
    ))
  } else if (family_name == "multinomial") {
    data[[outcome]] <- as.factor(data[[outcome]])
    if (nlevels(data[[outcome]]) < 3L) stop("多项 Logistic 结局至少需要三个无序水平。", call. = FALSE)
    if (nzchar(outcome_reference)) {
      if (!outcome_reference %in% levels(data[[outcome]])) stop("多项结局参照水平不存在。", call. = FALSE)
      data[[outcome]] <- stats::relevel(data[[outcome]], ref = outcome_reference)
    }
    if (any(table(data[[outcome]]) < 10L)) warnings <- c(warnings, "多项结局至少一个类别少于 10 例，估计可能不稳定。")
    model <- nnet::multinom(formula, data = data, trace = FALSE, Hess = TRUE)
    summary_model_raw <- summary(model)
    estimates <- as.matrix(summary_model_raw$coefficients)
    errors <- as.matrix(summary_model_raw$standard.errors)
    coefficient_rows <- list()
    for (level_index in seq_len(nrow(estimates))) {
      matrix <- cbind(estimates[level_index, ], errors[level_index, ])
      rownames(matrix) <- colnames(estimates)
      frame <- coefficient_frame(matrix, confidence_level, TRUE, "relative_risk_ratio")
      frame$outcome_level <- rownames(estimates)[level_index]
      coefficient_rows[[length(coefficient_rows) + 1L]] <- frame
    }
    coefficients <- do.call(rbind, coefficient_rows)
    method_id <- "multinomial-logistic"
    diagnostics <- list(list(
      diagnostic = "模型收敛",
      value = model$convergence,
      rule = "0 表示优化器收敛",
      status = ifelse(model$convergence == 0, "pass", "fail")
    ))
  } else {
    data[[outcome]] <- safe_numeric(data[[outcome]])
    if (any(!is.finite(data[[outcome]])) || any(data[[outcome]] < 0) || any(abs(data[[outcome]] - round(data[[outcome]])) > 1e-8)) {
      stop("计数回归结局必须为非负整数。", call. = FALSE)
    }
    if (nzchar(offset_variable)) {
      offset_values <- safe_numeric(data[[offset_variable]])
      if (any(!is.finite(offset_values)) || any(offset_values <= 0)) stop("offset 暴露量必须为正数。", call. = FALSE)
      formula <- stats::update(formula, paste0(". ~ . + offset(log(", quote_name(offset_variable), "))"))
    }
    if (family_name == "poisson") {
      model <- stats::glm(formula, data = data, family = stats::poisson())
      method_id <- "poisson"
    } else {
      model <- MASS::glm.nb(formula, data = data)
      method_id <- "negative-binomial"
    }
    coef_matrix <- summary(model)$coefficients
    coefficients <- coefficient_frame(coef_matrix, confidence_level, TRUE, "incidence_rate_ratio")
    pearson <- stats::residuals(model, type = "pearson")
    dispersion <- sum(pearson^2) / stats::df.residual(model)
    zero_observed <- mean(data[[outcome]] == 0)
    zero_expected <- mean(stats::dpois(0, lambda = stats::fitted(model)))
    diagnostics <- list(
      list(
        diagnostic = "离散比", value = dispersion,
        rule = "Poisson 中 >1.5 提示过度离散；负二项中作为拟合审计",
        status = if (family_name == "poisson" && dispersion > 1.5) "warning" else "pass"
      ),
      list(
        diagnostic = "观察与模型期望零比例差", value = zero_observed - zero_expected,
        rule = "绝对差 >0.10 提示需要审查零膨胀或模型设定",
        status = if (abs(zero_observed - zero_expected) > .10) "warning" else "pass"
      )
    )
    if (family_name == "poisson" && dispersion > 1.5) warnings <- c(warnings, "Poisson 模型存在过度离散迹象；建议考虑负二项回归或稳健方差敏感性分析。")
    if (abs(zero_observed - zero_expected) > .10) warnings <- c(warnings, "观察零值比例与模型期望差异较大；未自动改用零膨胀模型。")
  }
  if (subset$n_excluded_missing > 0L) warnings <- c(warnings, paste0("因模型变量缺失排除 ", subset$n_excluded_missing, " 行。"))
  log_likelihood <- tryCatch(as.numeric(stats::logLik(model)), error = function(e) NA_real_)
  model_summary <- data.frame(
    family = family_name, n = nrow(data), parameters = length(stats::coef(model)),
    log_likelihood = log_likelihood, aic = stats::AIC(model), bic = stats::BIC(model),
    outcome_reference = if (family_name == "multinomial") levels(data[[outcome]])[[1]] else NA_character_,
    stringsAsFactors = FALSE
  )
  diagnostics_table <- if (length(diagnostics)) {
    do.call(rbind, lapply(diagnostics, function(x) data.frame(
      diagnostic = x$diagnostic, value = as.character(x$value), rule = x$rule,
      status = x$status, message = as.character(x$message %||% ""), stringsAsFactors = FALSE
    )))
  } else data.frame(diagnostic=character(),value=character(),rule=character(),status=character(),message=character())
  model_path <- file.path(context$module_output_dir, "01_广义回归模型.rds")
  saveRDS(model, model_path)
  tables <- list(
    write_result_table(context, "generalized-regression", "01_广义回归系数", "广义回归系数", coefficients),
    write_result_table(context, "generalized-regression", "02_广义回归模型摘要", "广义回归模型摘要", model_summary),
    write_result_table(context, "generalized-regression", "03_广义回归诊断", "广义回归诊断", diagnostics_table)
  )
  new_module_result(
    "generalized-regression", method_id, started_at,
    tables = tables,
    model_objects = list(list(object_id="generalized_regression_model", path=relative_path(model_path, context$run_dir), source_module="generalized-regression")),
    diagnostics = diagnostics,
    warnings = unique(warnings),
    limitations = c("模型关联不自动具有因果解释。", "当前模块使用完整案例；多重插补结果需要模型特异的合并流程。"),
    narrative = c(paste0("以 ", outcome, " 为结局拟合 ", family_name, " 广义回归模型。")),
    sample = list(n_input=subset$n_input,n_complete=subset$n_complete,n_excluded_missing=subset$n_excluded_missing,parameters=parameter_count),
    random_seed = context$random_seed
  )
}
