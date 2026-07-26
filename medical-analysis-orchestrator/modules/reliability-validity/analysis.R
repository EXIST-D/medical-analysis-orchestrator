run_module <- function(config, context) {
  started_at <- utc_now()
  parameters <- module_parameters(config, "reliability-validity")
  scales <- parameters$scales %||% list()
  compute_omega <- isTRUE(parameters$compute_omega %||% TRUE)
  criterion_variables <- unique(as.character(parameters$criterion_variables %||% character()))
  criterion_method <- tolower(as.character(parameters$criterion_method %||% "spearman"))
  minimum_complete_n <- as.integer(parameters$minimum_complete_n %||% 30L)

  if (!length(scales) || is.null(names(scales)) || any(!nzchar(names(scales)))) {
    stop("信效度分析必须用具名 scales 明确每个量表及其条目。", call. = FALSE)
  }
  if (!criterion_method %in% c("pearson", "spearman", "kendall")) {
    stop("效标关联方法必须是 pearson、spearman 或 kendall。", call. = FALSE)
  }

  all_items <- unique(unlist(scales, use.names = FALSE))
  assert_columns(context$data, c(all_items, criterion_variables), "reliability-validity")
  reliability_rows <- list()
  item_rows <- list()
  factorability_rows <- list()
  criterion_rows <- list()
  analysis_objects <- list()
  warnings <- character()

  for (scale_name in names(scales)) {
    items <- unique(as.character(scales[[scale_name]]))
    if (length(items) < 3L) {
      stop("每个量表至少需要 3 个条目：", scale_name, call. = FALSE)
    }
    item_data <- as.data.frame(
      lapply(context$data[items], safe_numeric),
      check.names = FALSE
    )
    nonconstant <- vapply(item_data, function(x) stats::sd(x, na.rm = TRUE) > 0, logical(1))
    if (!all(nonconstant)) {
      stop(
        scale_name, " 存在常量或全缺失条目：",
        paste(items[!nonconstant], collapse = ", "),
        call. = FALSE
      )
    }
    complete_n <- sum(stats::complete.cases(item_data))
    if (complete_n < minimum_complete_n) {
      stop(
        scale_name, " 的完整案例数为 ", complete_n,
        "，低于配置阈值 ", minimum_complete_n, "。",
        call. = FALSE
      )
    }
    if (complete_n < 100L) {
      warnings <- c(warnings, paste0(scale_name, " 完整案例少于 100，信效度估计可能不稳定。"))
    }

    alpha_object <- suppressWarnings(psych::alpha(
      item_data,
      check.keys = FALSE,
      warnings = FALSE,
      use = "pairwise"
    ))
    omega_object <- NULL
    if (compute_omega) {
      omega_object <- tryCatch(
        suppressWarnings(psych::omega(
          item_data,
          nfactors = 1,
          plot = FALSE,
          warnings = FALSE,
          flip = FALSE
        )),
        error = function(condition) {
          warnings <<- c(
            warnings,
            paste0(scale_name, " 的 McDonald’s ω 计算失败：", conditionMessage(condition))
          )
          NULL
        }
      )
    }

    alpha_total <- alpha_object$total
    raw_alpha <- unname(alpha_total$raw_alpha)
    standardized_alpha <- unname(alpha_total$std.alpha)
    omega_total <- if (!is.null(omega_object$omega.tot)) unname(omega_object$omega.tot) else NA_real_
    omega_hierarchical <- if (!is.null(omega_object$omega_h)) unname(omega_object$omega_h) else NA_real_
    reliability_rows[[length(reliability_rows) + 1L]] <- data.frame(
      scale = scale_name,
      items = length(items),
      n_complete = complete_n,
      cronbach_alpha = raw_alpha,
      standardized_alpha = standardized_alpha,
      guttman_g6 = unname(alpha_total[["G6(smc)"]]),
      average_interitem_r = unname(alpha_total$average_r),
      signal_noise_ratio = unname(alpha_total[["S/N"]]),
      omega_total = omega_total,
      omega_hierarchical = omega_hierarchical,
      stringsAsFactors = FALSE
    )
    if (is.finite(raw_alpha) && raw_alpha < .70) {
      warnings <- c(warnings, paste0(scale_name, " 的 Cronbach’s α < 0.70。"))
    }
    if (is.finite(omega_total) && omega_total < .70) {
      warnings <- c(warnings, paste0(scale_name, " 的 McDonald’s ω < 0.70。"))
    }

    item_stats <- alpha_object$item.stats
    alpha_drop <- alpha_object$alpha.drop
    for (item in items) {
      item_rows[[length(item_rows) + 1L]] <- data.frame(
        scale = scale_name,
        item = item,
        n = item_stats[item, "n"],
        mean = item_stats[item, "mean"],
        sd = item_stats[item, "sd"],
        raw_item_total_r = item_stats[item, "raw.r"],
        corrected_item_total_r = item_stats[item, "r.drop"],
        alpha_if_deleted = alpha_drop[item, "raw_alpha"],
        stringsAsFactors = FALSE
      )
    }

    correlation_matrix <- stats::cor(item_data, use = "pairwise.complete.obs")
    kmo <- psych::KMO(correlation_matrix)
    bartlett <- psych::cortest.bartlett(correlation_matrix, n = complete_n)
    factorability_rows[[length(factorability_rows) + 1L]] <- data.frame(
      scale = scale_name,
      n_complete = complete_n,
      kmo_overall = unname(kmo$MSA),
      bartlett_chisq = unname(bartlett$chisq),
      bartlett_df = unname(bartlett$df),
      bartlett_p_value = unname(bartlett$p.value),
      stringsAsFactors = FALSE
    )
    if (is.finite(kmo$MSA) && kmo$MSA < .60) {
      warnings <- c(warnings, paste0(scale_name, " 的总体 KMO < 0.60。"))
    }

    if (length(criterion_variables)) {
      scale_score <- rowMeans(item_data, na.rm = TRUE)
      scale_score[rowSums(!is.na(item_data)) == 0L] <- NA_real_
      for (criterion in criterion_variables) {
        criterion_value <- safe_numeric(context$data[[criterion]])
        keep <- stats::complete.cases(scale_score, criterion_value)
        if (sum(keep) < 3L || stats::sd(criterion_value[keep]) == 0) {
          warnings <- c(warnings, paste0(scale_name, " 与效标 ", criterion, " 的有效样本不足或效标为常量。"))
          next
        }
        test <- suppressWarnings(stats::cor.test(
          scale_score[keep],
          criterion_value[keep],
          method = criterion_method,
          exact = FALSE
        ))
        confidence <- if (!is.null(test$conf.int)) unname(test$conf.int) else c(NA_real_, NA_real_)
        criterion_rows[[length(criterion_rows) + 1L]] <- data.frame(
          scale = scale_name,
          criterion = criterion,
          n = sum(keep),
          method = criterion_method,
          coefficient = unname(test$estimate),
          conf_low = confidence[[1]],
          conf_high = confidence[[2]],
          p_value = test$p.value,
          stringsAsFactors = FALSE
        )
      }
    }
    analysis_objects[[scale_name]] <- list(alpha = alpha_object, omega = omega_object)
  }

  reliability_table <- do.call(rbind, reliability_rows)
  item_table <- do.call(rbind, item_rows)
  factorability_table <- do.call(rbind, factorability_rows)
  criterion_table <- if (length(criterion_rows)) do.call(rbind, criterion_rows) else data.frame(
    scale = character(), criterion = character(), n = integer(),
    method = character(), coefficient = numeric(), conf_low = numeric(),
    conf_high = numeric(), p_value = numeric()
  )

  model_path <- file.path(context$module_output_dir, "01_信效度分析对象.rds")
  saveRDS(analysis_objects, model_path)
  tables <- list(
    write_result_table(
      context, "reliability-validity", "01_量表信度汇总",
      "量表信度汇总", reliability_table,
      c("α 与 ω 的阈值仅作常规筛查，不能脱离量表用途、维度结构和样本解释。")
    ),
    write_result_table(
      context, "reliability-validity", "02_条目分析",
      "条目分析", item_table,
      c("低校正条目-总分相关只用于标记；本模块不自动删除或反向计分条目。")
    ),
    write_result_table(
      context, "reliability-validity", "03_结构效度前提检查",
      "结构效度前提检查", factorability_table,
      c("KMO 与 Bartlett 检验只反映因子分析适用性，不单独证明结构效度。")
    ),
    write_result_table(
      context, "reliability-validity", "04_效标关联效度",
      "效标关联效度", criterion_table,
      c("效标相关属于关联证据；效标选择和方向必须由研究方案预先确认。")
    )
  )

  new_module_result(
    "reliability-validity", "scale-reliability-validity", started_at,
    tables = tables,
    model_objects = list(list(
      object_id = "reliability_validity_objects",
      path = relative_path(model_path, context$run_dir),
      source_module = "reliability-validity"
    )),
    warnings = unique(warnings),
    limitations = c(
      "内部一致性不是量表单维性的充分证据。",
      "完整的内容效度、跨群体测量等值性和重测信度需要额外设计与数据。"
    ),
    narrative = c(paste0("对 ", length(scales), " 个预先定义量表执行信度与效度筛查。")),
    sample = list(n_input = nrow(context$data), scales = as.list(names(scales))),
    random_seed = context$random_seed
  )
}
