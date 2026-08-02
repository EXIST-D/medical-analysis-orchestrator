run_module <- function(config, context) {
  started_at <- utc_now()
  parameters <- module_parameters(config, "factor-analysis")
  items <- unique(as.character(parameters$items %||% character()))
  efa_config <- parameters$efa %||% list()
  cfa_config <- parameters$cfa %||% list()
  validation_config <- parameters$validation %||% list()
  run_efa <- isTRUE(efa_config$enabled)
  run_cfa <- isTRUE(cfa_config$enabled)
  if (length(items) < 3L) stop("因子分析至少需要 3 个条目。", call. = FALSE)
  if (!run_efa && !run_cfa) stop("必须在方案中明确启用 EFA、CFA 或两者。", call. = FALSE)
  assert_columns(context$data, items, "factor-analysis")

  item_data <- as.data.frame(lapply(context$data[items], safe_numeric), check.names = FALSE)
  nonconstant <- vapply(item_data, function(x) stats::sd(x, na.rm = TRUE) > 0, logical(1))
  if (!all(nonconstant)) {
    stop("因子分析存在常量或全缺失条目：", paste(items[!nonconstant], collapse = ", "), call. = FALSE)
  }
  complete_data <- item_data[stats::complete.cases(item_data), , drop = FALSE]
  n_complete <- nrow(complete_data)
  if (n_complete < 50L || n_complete / length(items) < 3) {
    stop("因子分析样本不足：至少需要 50 个完整案例且每条目至少 3 个案例。", call. = FALSE)
  }
  warnings <- character()
  if (n_complete < 100L || n_complete / length(items) < 5) {
    warnings <- c(warnings, "因子分析样本低于常用的 100 例或每条目 5 例经验标准，结果可能不稳定。")
  }
  validation_enabled <- isTRUE(validation_config$enabled)
  efa_data <- complete_data
  cfa_data <- item_data
  split_table <- data.frame(
    dataset = "full_analysis_data", n = n_complete,
    role = "EFA/CFA shared sample", stringsAsFactors = FALSE
  )
  if (validation_enabled) {
    split_method <- tolower(as.character(validation_config$split_method %||% "random"))
    train_fraction <- as.numeric(validation_config$train_fraction %||% .7)
    if (split_method != "random" || !is.finite(train_fraction) || train_fraction <= .5 || train_fraction >= .9) {
      stop("独立验证仅支持 random 划分，且 train_fraction 必须在 0.5 与 0.9 之间。", call. = FALSE)
    }
    n_train <- floor(n_complete * train_fraction)
    n_validation <- n_complete - n_train
    if (n_train < 50L || n_validation < 50L || n_train / length(items) < 3 || n_validation / length(items) < 3) {
      stop("EFA/CFA 独立验证划分后每个样本均需至少 50 个完整案例且每条目至少 3 个案例。", call. = FALSE)
    }
    set.seed(context$random_seed)
    train_index <- sample.int(n_complete, n_train, replace = FALSE)
    efa_data <- complete_data[train_index, , drop = FALSE]
    cfa_data <- complete_data[-train_index, , drop = FALSE]
    split_table <- data.frame(
      dataset = c("efa_development", "cfa_independent_validation"),
      n = c(nrow(efa_data), nrow(cfa_data)),
      role = c("结构探索", "独立验证"),
      stringsAsFactors = FALSE
    )
    warnings <- c(warnings, "EFA 与 CFA 使用随机划分的独立完整案例子样本；此划分不是外部验证。")
  }
  correlation_matrix <- stats::cor(item_data, use = "pairwise.complete.obs")
  kmo <- psych::KMO(correlation_matrix)
  bartlett <- psych::cortest.bartlett(correlation_matrix, n = n_complete)
  factorability_table <- data.frame(
    n_complete = n_complete,
    items = length(items),
    cases_per_item = n_complete / length(items),
    kmo_overall = unname(kmo$MSA),
    bartlett_chisq = unname(bartlett$chisq),
    bartlett_df = unname(bartlett$df),
    bartlett_p_value = unname(bartlett$p.value),
    stringsAsFactors = FALSE
  )
  if (is.finite(kmo$MSA) && kmo$MSA < .60) {
    warnings <- c(warnings, "总体 KMO < 0.60，因子结构可能不稳定。")
  }

  tables <- list(write_result_table(
    context, "factor-analysis", "01_因子分析适用性检查",
    "因子分析适用性检查", factorability_table,
    c("KMO、Bartlett 和样本量应结合条目性质与研究设计判断。")
  ))
  tables <- c(tables, list(write_result_table(
    context, "factor-analysis", "02_因子分析样本划分",
    "EFA/CFA 样本划分", split_table,
    c("独立划分减少同一数据既探索又验证造成的乐观偏倚，但不能替代外部样本验证。")
  )))
  figures <- list()
  model_objects <- list()
  efa_object <- NULL
  cfa_object <- NULL

  if (run_efa) {
    factors <- as.integer(efa_config$factors %||% NA_integer_)
    if (!is.finite(factors) || factors < 1L || factors >= length(items)) {
      stop("EFA 因子数必须由方案明确确认，且介于 1 与条目数减 1 之间。", call. = FALSE)
    }
    extraction <- tolower(as.character(efa_config$extraction %||% "minres"))
    rotation <- tolower(as.character(efa_config$rotation %||% "oblimin"))
    if (!extraction %in% c("minres", "ml", "pa")) {
      stop("EFA 提取方法仅支持 minres、ml 或 pa。", call. = FALSE)
    }
    if (!rotation %in% c("oblimin", "varimax", "promax", "none")) {
      stop("EFA 旋转方法仅支持 oblimin、varimax、promax 或 none。", call. = FALSE)
    }
    parallel_object <- NULL
    if (isTRUE(efa_config$parallel_analysis)) {
      set.seed(context$random_seed)
      parallel_object <- suppressWarnings(psych::fa.parallel(
        efa_data,
        fm = extraction,
        fa = "fa",
        n.iter = as.integer(efa_config$parallel_iterations %||% 50L),
        plot = FALSE,
        show.legend = FALSE
      ))
      if (!is.null(parallel_object$nfact) && parallel_object$nfact != factors) {
        warnings <- c(
          warnings,
          paste0("平行分析建议 ", parallel_object$nfact, " 个因子，与确认的 ", factors, " 因子方案不同。")
        )
      }
    }
    efa_object <- suppressWarnings(psych::fa(
      stats::cor(efa_data, use = "pairwise.complete.obs"),
      nfactors = factors,
      n.obs = nrow(efa_data),
      rotate = rotation,
      fm = extraction,
      warnings = FALSE
    ))
    loading_matrix <- unclass(efa_object$loadings)
    loading_table <- data.frame(
      item = rownames(loading_matrix),
      loading_matrix,
      communality = unname(efa_object$communality),
      uniqueness = unname(efa_object$uniquenesses),
      check.names = FALSE,
      row.names = NULL
    )
    variance_table <- data.frame(
      metric = rownames(efa_object$Vaccounted),
      efa_object$Vaccounted,
      check.names = FALSE,
      row.names = NULL
    )
    tables <- c(tables, list(
      write_result_table(
        context, "factor-analysis", "03_EFA因子载荷",
        "EFA 因子载荷", loading_table,
        c(paste0("确认因子数=", factors, "；提取=", extraction, "；旋转=", rotation, "。"))
      ),
      write_result_table(
        context, "factor-analysis", "04_EFA因子解释",
        "EFA 因子解释", variance_table,
        c("因子数不得只根据单一经验阈值或显著性结果事后调整。")
      )
    ))
    observed_eigen <- eigen(correlation_matrix, symmetric = TRUE, only.values = TRUE)$values
    parallel_values <- rep(NA_real_, length(observed_eigen))
    if (!is.null(parallel_object$fa.sim)) {
      available_parallel <- as.numeric(parallel_object$fa.sim)
      parallel_values[seq_len(min(
        length(parallel_values), length(available_parallel)
      ))] <- available_parallel[seq_len(min(
        length(parallel_values), length(available_parallel)
      ))]
    }
    figure_source <- data.frame(
      factor_index = seq_along(observed_eigen),
      observed_eigenvalue = observed_eigen,
      random_data_95th_percentile = parallel_values,
      stringsAsFactors = FALSE
    )
    source_data_path <- write_figure_source_data(
      context, "efa_scree_parallel", figure_source
    )
    plot_efa_scree <- function() {
      palette <- medical_figure_palette()
      graphics::plot(
        figure_source$factor_index, figure_source$observed_eigenvalue,
        type = "b", pch = 19, xlab = "因子序号", ylab = "特征值",
        main = "碎石图与平行分析", col = palette[["accent"]]
      )
      graphics::abline(h = 1, lty = 3, col = palette[["neutral"]])
      if (any(is.finite(figure_source$random_data_95th_percentile))) {
        graphics::lines(
          figure_source$factor_index,
          figure_source$random_data_95th_percentile,
          type = "b", pch = 1, lty = 2, col = palette[["warning"]]
        )
        graphics::legend(
          "topright", legend = c("观察特征值", "随机数据95%分位"),
          lty = c(1, 2), pch = c(19, 1),
          col = c(palette[["accent"]], palette[["warning"]]), bty = "n"
        )
      }
    }
    figure_exports <- export_r_figure(
      config,
      context,
      "01_碎石图与平行分析",
      plot_efa_scree,
      width_mm = 150,
      height_mm = 100
    )
    figures <- c(figures, list(new_figure_object(
      figure_id = "efa_scree_parallel",
      title = "碎石图与平行分析",
      exports = figure_exports,
      source_data_path = source_data_path,
      conclusion = paste0(
        "以观察特征值、随机数据基准和预先确认的 ",
        factors, " 因子方案共同审计因子保留。"
      ),
      evidence_role = "factor_retention_diagnostic",
      statistics = list(
        n_definition = paste0(n_complete, " 个完整基线案例"),
        biological_replicates = "不适用；问卷受试者为独立分析单位",
        technical_replicates = "不适用",
        center_statistic = "相关矩阵特征值",
        interval = "平行分析随机数据第95百分位",
        test = paste0("EFA 平行分析；提取方法=", extraction),
        multiple_comparison_correction = "不适用"
      ),
      source_module = "factor-analysis"
    )))
    efa_path <- file.path(context$module_output_dir, "01_EFA分析对象.rds")
    saveRDS(list(efa = efa_object, parallel = parallel_object), efa_path)
    model_objects <- c(model_objects, list(list(
      object_id = "efa_object",
      path = relative_path(efa_path, context$run_dir),
      source_module = "factor-analysis"
    )))
  }

  if (run_cfa) {
    model_syntax <- as.character(cfa_config$model %||% "")
    if (!nzchar(model_syntax)) stop("CFA 必须提供用户确认的 lavaan 模型语法。", call. = FALSE)
    estimator <- toupper(as.character(cfa_config$estimator %||% "MLR"))
    ordered <- unique(as.character(cfa_config$ordered %||% character()))
    if (length(setdiff(ordered, items))) stop("CFA ordered 中存在未注册条目。", call. = FALSE)
    missing_method <- as.character(cfa_config$missing %||% "fiml")
    if (length(ordered) && tolower(missing_method) == "fiml") {
      stop("有序条目 CFA 不能使用 FIML；请确认 WLSMV 与 pairwise/listwise 缺失策略。", call. = FALSE)
    }
    cfa_object <- suppressWarnings(lavaan::cfa(
      model = model_syntax,
      data = cfa_data,
      estimator = estimator,
      ordered = if (length(ordered)) ordered else NULL,
      missing = missing_method,
      std.lv = isTRUE(cfa_config$std_lv %||% TRUE)
    ))
    converged <- isTRUE(lavaan::lavInspect(cfa_object, "converged"))
    if (!converged) stop("CFA 模型未收敛。", call. = FALSE)
    requested_fit <- c(
      "chisq", "df", "pvalue", "cfi", "tli", "rmsea",
      "rmsea.ci.lower", "rmsea.ci.upper", "srmr", "aic", "bic"
    )
    available_fit <- lavaan::fitMeasures(cfa_object)
    selected_fit <- available_fit[intersect(requested_fit, names(available_fit))]
    fit_table <- data.frame(
      metric = names(selected_fit),
      value = unname(selected_fit),
      stringsAsFactors = FALSE
    )
    standardized <- lavaan::standardizedSolution(cfa_object)
    loading_rows <- standardized[standardized$op == "=~", , drop = FALSE]
    loading_table <- loading_rows[, intersect(
      c("lhs", "op", "rhs", "est.std", "se", "z", "pvalue", "ci.lower", "ci.upper"),
      names(loading_rows)
    ), drop = FALSE]
    names(loading_table)[names(loading_table) == "est.std"] <- "standardized_loading"

    factors <- unique(loading_rows$lhs)
    residual_rows <- standardized[
      standardized$op == "~~" & standardized$lhs == standardized$rhs,
      , drop = FALSE
    ]
    reliability_rows <- lapply(factors, function(factor_name) {
      factor_loadings <- loading_rows[loading_rows$lhs == factor_name, , drop = FALSE]
      indicator_names <- factor_loadings$rhs
      theta <- residual_rows$est.std[match(indicator_names, residual_rows$lhs)]
      lambda <- factor_loadings$est.std
      data.frame(
        factor = factor_name,
        indicators = length(lambda),
        composite_reliability = sum(lambda, na.rm = TRUE)^2 /
          (sum(lambda, na.rm = TRUE)^2 + sum(theta, na.rm = TRUE)),
        ave = sum(lambda^2, na.rm = TRUE) /
          (sum(lambda^2, na.rm = TRUE) + sum(theta, na.rm = TRUE)),
        stringsAsFactors = FALSE
      )
    })
    reliability_table <- do.call(rbind, reliability_rows)
    if (any(reliability_table$ave < .50, na.rm = TRUE)) {
      warnings <- c(warnings, "至少一个 CFA 因子的 AVE < 0.50。")
    }
    if (any(reliability_table$composite_reliability < .70, na.rm = TRUE)) {
      warnings <- c(warnings, "至少一个 CFA 因子的组合信度 < 0.70。")
    }

    discriminant_rows <- list()
    if (length(factors) >= 2L) {
      factor_pairs <- utils::combn(factors, 2L, simplify = FALSE)
      for (pair in factor_pairs) {
        row <- standardized[
          standardized$op == "~~" &
            ((standardized$lhs == pair[[1]] & standardized$rhs == pair[[2]]) |
             (standardized$lhs == pair[[2]] & standardized$rhs == pair[[1]])),
          , drop = FALSE
        ]
        correlation <- if (nrow(row)) row$est.std[[1]] else NA_real_
        ave_1 <- reliability_table$ave[reliability_table$factor == pair[[1]]]
        ave_2 <- reliability_table$ave[reliability_table$factor == pair[[2]]]
        discriminant_rows[[length(discriminant_rows) + 1L]] <- data.frame(
          factor_1 = pair[[1]],
          factor_2 = pair[[2]],
          latent_correlation = correlation,
          shared_variance = correlation^2,
          ave_factor_1 = ave_1,
          ave_factor_2 = ave_2,
          fornell_larcker_pass = is.finite(correlation) && min(ave_1, ave_2) > correlation^2,
          stringsAsFactors = FALSE
        )
      }
    }
    discriminant_table <- if (length(discriminant_rows)) do.call(rbind, discriminant_rows) else data.frame(
      factor_1 = character(), factor_2 = character(), latent_correlation = numeric(),
      shared_variance = numeric(), ave_factor_1 = numeric(), ave_factor_2 = numeric(),
      fornell_larcker_pass = logical()
    )
    mi_threshold <- as.numeric(cfa_config$modification_index_threshold %||% 10)
    modification_table <- lavaan::modificationIndices(
      cfa_object, sort. = TRUE, minimum.value = mi_threshold
    )
    modification_table <- modification_table[, intersect(
      c("lhs", "op", "rhs", "mi", "epc", "sepc.lv", "sepc.all", "sepc.nox"),
      names(modification_table)
    ), drop = FALSE]
    tables <- c(tables, list(
      write_result_table(context, "factor-analysis", "05_CFA拟合指标", "CFA 拟合指标", fit_table),
      write_result_table(
        context, "factor-analysis", "06_CFA标准化载荷", "CFA 标准化载荷", loading_table,
        c(paste0("估计量=", estimator, "；缺失策略=", missing_method, "。"))
      ),
      write_result_table(
        context, "factor-analysis", "07_CFA组合信度与AVE",
        "CFA 组合信度与平均方差提取量", reliability_table
      ),
      write_result_table(
        context, "factor-analysis", "08_CFA区分效度",
        "CFA 区分效度", discriminant_table,
        c("Fornell–Larcker 仅是区分效度证据之一。")
      ),
      write_result_table(
        context, "factor-analysis", "09_CFA修改指数",
        "CFA 修改指数", modification_table,
        c("修改指数不得作为无理论依据的数据驱动改模指令。")
      )
    ))
    cfa_path <- file.path(context$module_output_dir, "02_CFA模型.rds")
    saveRDS(cfa_object, cfa_path)
    model_objects <- c(model_objects, list(list(
      object_id = "cfa_model",
      path = relative_path(cfa_path, context$run_dir),
      source_module = "factor-analysis"
    )))
    cfi <- unname(available_fit["cfi"])
    rmsea <- unname(available_fit["rmsea"])
    srmr <- unname(available_fit["srmr"])
    if (is.finite(cfi) && cfi < .90) warnings <- c(warnings, "CFA CFI < 0.90。")
    if (is.finite(rmsea) && rmsea > .08) warnings <- c(warnings, "CFA RMSEA > 0.08。")
    if (is.finite(srmr) && srmr > .08) warnings <- c(warnings, "CFA SRMR > 0.08。")
  }

  method_id <- paste(c(if (run_efa) "efa", if (run_cfa) "cfa"), collapse = "-and-")
  new_module_result(
    "factor-analysis", method_id, started_at,
    tables = tables,
    figures = figures,
    model_objects = model_objects,
    warnings = unique(warnings),
    limitations = c(
      "EFA 与 CFA 的因子数和模型语法必须由理论与预先方案支持。",
      "修改指数、载荷阈值和拟合指标不能替代理论判断或独立样本验证。"
    ),
    narrative = c(paste0(
      "对 ", length(items), " 个条目执行",
      if (run_efa && run_cfa) " EFA 与 CFA。" else if (run_efa) " EFA。" else " CFA。"
    )),
    sample = list(
      n_input = nrow(context$data),
      n_complete = n_complete,
      n_efa = nrow(efa_data),
      n_cfa = if (validation_enabled) nrow(cfa_data) else n_complete,
      independent_validation_split = validation_enabled,
      items = as.list(items)
    ),
    random_seed = context$random_seed
  )
}
