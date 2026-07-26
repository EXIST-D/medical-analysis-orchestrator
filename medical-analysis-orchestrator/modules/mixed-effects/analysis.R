run_module <- function(config, context) {
  started_at <- utc_now()
  parameters <- module_parameters(config, "mixed-effects")
  family_name <- tolower(as.character(parameters$family %||% "gaussian"))
  outcome <- as.character(parameters$outcome %||% "")
  fixed_effects <- unique(as.character(parameters$fixed_effects %||% character()))
  interactions <- parameters$interactions %||% list()
  categorical <- unique(as.character(parameters$categorical %||% character()))
  group_variable <- as.character(parameters$group %||% "")
  random_intercept <- isTRUE(parameters$random_intercept %||% TRUE)
  random_slopes <- unique(as.character(parameters$random_slopes %||% character()))
  correlated <- isTRUE(parameters$correlated_random_effects %||% TRUE)
  optimizer <- as.character(parameters$optimizer %||% "bobyqa")
  if (!family_name %in% c("gaussian", "binomial")) {
    stop("混合效应模型当前仅支持 gaussian 或 binomial。", call. = FALSE)
  }
  if (!nzchar(outcome) || !length(fixed_effects) || !nzchar(group_variable)) {
    stop("混合效应模型必须指定结局、固定效应和分组变量。", call. = FALSE)
  }
  if (!random_intercept && !length(random_slopes)) {
    stop("随机效应至少需要随机截距或一个随机斜率。", call. = FALSE)
  }

  interaction_variables <- unique(unlist(interactions, use.names = FALSE))
  variables <- unique(c(outcome, fixed_effects, interaction_variables, group_variable, random_slopes))
  assert_columns(context$data, variables, "mixed-effects")
  subset <- analysis_subset(context$data, variables)
  data <- subset$data
  for (variable in intersect(categorical, names(data))) data[[variable]] <- as.factor(data[[variable]])
  reference_levels <- utils::modifyList(
    config$variables$reference_levels %||% list(),
    parameters$reference_levels %||% list()
  )
  data <- apply_reference_levels(data, reference_levels)
  data[[group_variable]] <- as.factor(data[[group_variable]])
  group_counts <- table(data[[group_variable]])
  group_levels <- length(group_counts)
  if (group_levels < 3L) stop("混合效应模型至少需要 3 个随机效应组。", call. = FALSE)
  if (nrow(data) <= group_levels) stop("混合效应模型需要组内重复观测。", call. = FALSE)
  if (length(random_slopes)) {
    nonnumeric_slopes <- random_slopes[
      !vapply(data[random_slopes], is.numeric, logical(1))
    ]
    if (length(nonnumeric_slopes)) {
      stop("当前随机斜率必须是数值变量：", paste(nonnumeric_slopes, collapse = ", "), call. = FALSE)
    }
  }

  if (family_name == "gaussian") {
    data[[outcome]] <- safe_numeric(data[[outcome]])
    if (stats::sd(data[[outcome]]) == 0) stop("连续结局为常量。", call. = FALSE)
  } else {
    event_level <- as.character(parameters$event_level %||% "")
    observed_levels <- unique(as.character(data[[outcome]]))
    if (length(observed_levels) != 2L || !event_level %in% observed_levels) {
      stop("二项混合模型必须有两个结局水平，并明确有效 event_level。", call. = FALSE)
    }
    data[[outcome]] <- as.integer(as.character(data[[outcome]]) == event_level)
  }

  fixed_terms <- vapply(fixed_effects, quote_name, character(1))
  if (length(interactions)) {
    interaction_terms <- vapply(interactions, function(pair) {
      pair <- as.character(pair)
      if (length(pair) < 2L) stop("每个交互项至少包含两个变量。", call. = FALSE)
      paste(vapply(pair, quote_name, character(1)), collapse = ":")
    }, character(1))
    fixed_terms <- unique(c(fixed_terms, interaction_terms))
  }
  random_parts <- c(if (random_intercept) "1" else "0", vapply(random_slopes, quote_name, character(1)))
  random_operator <- if (correlated) "|" else "||"
  random_term <- paste0(
    "(", paste(random_parts, collapse = " + "), " ", random_operator, " ",
    quote_name(group_variable), ")"
  )
  formula <- stats::as.formula(paste(
    quote_name(outcome), "~", paste(c(fixed_terms, random_term), collapse = " + ")
  ))

  fit_warnings <- character()
  model <- withCallingHandlers(
    if (family_name == "gaussian") {
      lmerTest::lmer(
        formula,
        data = data,
        REML = isTRUE(parameters$reml %||% TRUE),
        control = lme4::lmerControl(
          optimizer = optimizer,
          optCtrl = list(maxfun = 100000)
        )
      )
    } else {
      lme4::glmer(
        formula,
        data = data,
        family = stats::binomial(),
        control = lme4::glmerControl(
          optimizer = optimizer,
          optCtrl = list(maxfun = 100000)
        )
      )
    },
    warning = function(condition) {
      fit_warnings <<- c(fit_warnings, conditionMessage(condition))
      invokeRestart("muffleWarning")
    }
  )
  summary_model <- summary(model)
  coefficient_matrix <- summary_model$coefficients
  statistic_column <- intersect(c("t value", "z value"), colnames(coefficient_matrix))[[1]]
  p_column <- intersect(c("Pr(>|t|)", "Pr(>|z|)"), colnames(coefficient_matrix))
  p_values <- if (length(p_column)) coefficient_matrix[, p_column[[1]]] else
    2 * stats::pnorm(abs(coefficient_matrix[, statistic_column]), lower.tail = FALSE)
  df_values <- if ("df" %in% colnames(coefficient_matrix)) coefficient_matrix[, "df"] else NA_real_
  fixed_table <- data.frame(
    term = rownames(coefficient_matrix),
    estimate = coefficient_matrix[, "Estimate"],
    std_error = coefficient_matrix[, "Std. Error"],
    df = df_values,
    statistic = coefficient_matrix[, statistic_column],
    p_value = p_values,
    conf_low = coefficient_matrix[, "Estimate"] - 1.96 * coefficient_matrix[, "Std. Error"],
    conf_high = coefficient_matrix[, "Estimate"] + 1.96 * coefficient_matrix[, "Std. Error"],
    effect_scale = if (family_name == "binomial") "log_odds" else "outcome_units",
    stringsAsFactors = FALSE,
    row.names = NULL
  )
  if (family_name == "binomial") {
    fixed_table$odds_ratio <- exp(fixed_table$estimate)
    fixed_table$or_conf_low <- exp(fixed_table$conf_low)
    fixed_table$or_conf_high <- exp(fixed_table$conf_high)
  }

  random_table <- as.data.frame(lme4::VarCorr(model))
  random_table <- random_table[, intersect(
    c("grp", "var1", "var2", "vcov", "sdcor"), names(random_table)
  ), drop = FALSE]
  singular <- lme4::isSingular(model, tol = 1e-4)
  optimizer_code <- model@optinfo$conv$opt %||% 0L
  convergence_messages <- model@optinfo$conv$lme4$messages %||% character()
  non_singular_messages <- convergence_messages[
    !grepl("singular", convergence_messages, ignore.case = TRUE)
  ]
  convergence_text <- paste(non_singular_messages, collapse = " | ")
  converged <- isTRUE(as.integer(optimizer_code) == 0L) &&
    !length(non_singular_messages)
  dropped_columns <- attr(lme4::getME(model, "X"), "col.dropped")
  dropped_n <- if (is.null(dropped_columns)) 0L else length(dropped_columns)
  random_variance <- sum(random_table$vcov[random_table$grp != "Residual" & is.na(random_table$var2)], na.rm = TRUE)
  residual_variance <- if (family_name == "gaussian") stats::sigma(model)^2 else (pi^2 / 3)
  icc <- random_variance / (random_variance + residual_variance)
  pearson_residuals <- stats::residuals(model, type = "pearson")
  overdispersion_ratio <- if (family_name == "binomial") {
    sum(pearson_residuals^2) / max(1, stats::df.residual(model))
  } else {
    NA_real_
  }
  model_summary <- data.frame(
    family = family_name,
    n = stats::nobs(model),
    groups = group_levels,
    min_observations_per_group = min(group_counts),
    median_observations_per_group = stats::median(as.numeric(group_counts)),
    fixed_parameters = length(lme4::fixef(model)),
    random_parameters = length(lme4::getME(model, "theta")),
    reml = if (family_name == "gaussian") isTRUE(parameters$reml %||% TRUE) else FALSE,
    aic = stats::AIC(model),
    bic = stats::BIC(model),
    log_likelihood = as.numeric(stats::logLik(model)),
    icc_latent_scale = icc,
    singular_fit = singular,
    converged = converged,
    stringsAsFactors = FALSE
  )
  diagnostics_table <- data.frame(
    diagnostic = c(
      "收敛", "奇异拟合", "随机效应组数", "每组中位观测数",
      "固定效应秩缺失列数", "Pearson过度离散比"
    ),
    value = c(
      as.numeric(converged), as.numeric(singular), group_levels,
      stats::median(as.numeric(group_counts)), dropped_n, overdispersion_ratio
    ),
    rule = c(
      "1=收敛", "1=随机效应协方差接近边界", "通常不应过少",
      "应支持组内重复测量", "0=固定效应矩阵满秩", "二项模型明显大于1提示过度离散"
    ),
    status = c(
      ifelse(converged, "pass", "fail"),
      ifelse(singular, "warning", "pass"),
      ifelse(group_levels < 5, "warning", "pass"),
      ifelse(stats::median(as.numeric(group_counts)) < 2, "fail", "pass"),
      ifelse(dropped_n > 0, "warning", "pass"),
      ifelse(is.na(overdispersion_ratio), "not_assessed", ifelse(overdispersion_ratio > 1.5, "warning", "pass"))
    ),
    stringsAsFactors = FALSE
  )
  warnings <- unique(fit_warnings)
  if (subset$n_excluded_missing > 0L) {
    warnings <- c(warnings, paste0("因模型变量缺失排除 ", subset$n_excluded_missing, " 行。"))
  }
  if (group_levels < 5L) warnings <- c(warnings, "随机效应组数少于 5，方差估计可能不稳定。")
  if (singular) warnings <- c(warnings, "模型为奇异拟合；随机效应结构可能过于复杂。")
  if (!converged) warnings <- c(warnings, paste0("模型收敛诊断失败：", convergence_text))
  if (dropped_n > 0L) warnings <- c(warnings, paste0("固定效应设计矩阵删除 ", dropped_n, " 个秩缺失列。"))
  if (is.finite(overdispersion_ratio) && overdispersion_ratio > 1.5) {
    warnings <- c(warnings, "二项混合模型存在过度离散迹象。")
  }

  fitted_values <- stats::fitted(model)
  figure_source <- data.frame(
    observation_index = seq_along(fitted_values),
    fitted_value = as.numeric(fitted_values),
    pearson_residual = as.numeric(pearson_residuals),
    observed_outcome = as.numeric(data[[outcome]]),
    stringsAsFactors = FALSE
  )
  source_data_path <- write_figure_source_data(
    context, "mixed_effects_diagnostics", figure_source
  )
  plot_mixed_diagnostics <- function() {
    old_par <- graphics::par(mfrow = c(1, 2), mar = c(4, 4, 3, 1))
    on.exit(graphics::par(old_par), add = TRUE)
    graphics::plot(
      figure_source$fitted_value, figure_source$pearson_residual,
      xlab = "拟合值", ylab = "Pearson残差", main = "残差与拟合值"
    )
    graphics::abline(h = 0, lty = 2, col = "grey50")
    if (family_name == "gaussian") {
      stats::qqnorm(figure_source$pearson_residual, main = "残差Q-Q图")
      stats::qqline(figure_source$pearson_residual, col = "grey50")
    } else {
      graphics::plot(
        figure_source$fitted_value,
        jitter(figure_source$observed_outcome, amount = .03),
        xlab = "预测概率", ylab = "观察结局",
        main = "预测概率与观察结局"
      )
    }
  }
  figure_exports <- export_r_figure(
    config,
    context,
    "01_混合效应模型诊断图",
    plot_mixed_diagnostics,
    width_mm = 183,
    height_mm = 92
  )
  model_path <- file.path(context$module_output_dir, "01_混合效应模型.rds")
  saveRDS(model, model_path)

  tables <- list(
    write_result_table(context, "mixed-effects", "01_固定效应", "混合效应模型固定效应", fixed_table),
    write_result_table(context, "mixed-effects", "02_随机效应", "混合效应模型随机效应", random_table),
    write_result_table(context, "mixed-effects", "03_模型摘要", "混合效应模型摘要", model_summary),
    write_result_table(
      context, "mixed-effects", "04_模型诊断", "混合效应模型诊断", diagnostics_table,
      c("奇异拟合和收敛问题只标记，不自动简化随机效应结构。")
    )
  )
  new_module_result(
    "mixed-effects",
    if (family_name == "gaussian") "linear-mixed-effects" else "binary-generalized-linear-mixed-effects",
    started_at,
    tables = tables,
    figures = list(new_figure_object(
      figure_id = "mixed_effects_diagnostics",
      title = "混合效应模型诊断图",
      exports = figure_exports,
      source_data_path = source_data_path,
      conclusion = "使用残差、拟合值和结局分布审计模型拟合质量；诊断图本身不证明因果关系。",
      evidence_role = "model_diagnostic",
      statistics = list(
        n_definition = paste0(
          subset$n_complete, " 次完整观测，来自 ",
          group_levels, " 个随机效应组"
        ),
        biological_replicates = paste0(group_levels, " 个受试者或聚类单位"),
        technical_replicates = "不适用",
        center_statistic = "模型拟合值与 Pearson 残差",
        interval = "不适用；诊断图不展示区间估计",
        test = if (family_name == "gaussian") {
          "线性混合效应模型残差诊断"
        } else {
          "二项广义线性混合效应模型拟合诊断"
        },
        multiple_comparison_correction = "不适用"
      ),
      source_module = "mixed-effects"
    )),
    model_objects = list(list(
      object_id = "mixed_effects_model",
      path = relative_path(model_path, context$run_dir),
      source_module = "mixed-effects"
    )),
    diagnostics = lapply(seq_len(nrow(diagnostics_table)), function(i) as.list(diagnostics_table[i, ])),
    warnings = unique(warnings),
    limitations = c(
      "随机效应结构必须由研究设计支持，不应仅按显著性自动删减。",
      "当前二项 GLMM 使用 Laplace 近似，性能和因果解释需要独立验证。"
    ),
    narrative = c(paste0(
      "以 ", outcome, " 为结局、", group_variable,
      " 为随机效应分组拟合 ", family_name, " 混合效应模型。"
    )),
    sample = list(
      n_input = subset$n_input,
      n_complete = subset$n_complete,
      n_excluded_missing = subset$n_excluded_missing,
      groups = group_levels
    ),
    random_seed = context$random_seed
  )
}
