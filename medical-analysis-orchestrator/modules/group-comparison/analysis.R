hedges_g <- function(x, y) {
  nx <- length(x); ny <- length(y)
  pooled <- sqrt(((nx - 1) * stats::var(x) + (ny - 1) * stats::var(y)) / (nx + ny - 2))
  if (!is.finite(pooled) || pooled == 0) return(NA_real_)
  correction <- 1 - 3 / (4 * (nx + ny) - 9)
  correction * (mean(y) - mean(x)) / pooled
}

paired_frame <- function(data, value, group, pair_id) {
  frame <- data.frame(value = safe_numeric(data[[value]]), group = as.factor(data[[group]]), pair_id = data[[pair_id]])
  frame <- frame[stats::complete.cases(frame), , drop = FALSE]
  frame$group <- droplevels(frame$group)
  levels <- levels(frame$group)
  if (length(levels) != 2L) stop("配对比较要求分组变量恰有两个有效水平。", call. = FALSE)
  duplicate_pairs <- duplicated(frame[c("pair_id", "group")])
  if (any(duplicate_pairs)) stop("同一 pair_id 在同一组内存在重复记录，不能自动配对。", call. = FALSE)
  wide <- reshape(frame, idvar = "pair_id", timevar = "group", direction = "wide")
  names(wide) <- sub("^value\\.", "", names(wide))
  complete <- wide[stats::complete.cases(wide[, levels, drop = FALSE]), c("pair_id", levels), drop = FALSE]
  names(complete) <- c("pair_id", "first", "second")
  complete
}

effect_ci_from_g <- function(g, n1, n2) {
  if (!is.finite(g) || n1 < 3L || n2 < 3L) return(c(NA_real_, NA_real_))
  se <- sqrt((n1 + n2) / (n1 * n2) + g^2 / (2 * (n1 + n2 - 2)))
  g + c(-1, 1) * stats::qnorm(.975) * se
}

run_module <- function(config, context) {
  started_at <- utc_now()
  parameters <- module_parameters(config, "group-comparison")
  data <- context$data
  group_variable <- as.character(parameters$group %||% "")
  pair_id <- as.character(parameters$pair_id %||% "")
  paired <- isTRUE(parameters$paired)
  continuous <- unique(as.character(parameters$continuous %||% character()))
  categorical <- unique(as.character(parameters$categorical %||% character()))
  method_requested <- tolower(as.character(parameters$continuous_method %||% "auto"))
  posthoc_requested <- tolower(as.character(parameters$posthoc %||% "none"))
  posthoc_adjust <- as.character(parameters$posthoc_adjust_method %||% config$data_handling$multiple_testing$method %||% "holm")
  confidence_level <- as.numeric(parameters$confidence_level %||% .95)
  if (!nzchar(group_variable)) stop("单因素分析必须指定分组变量。", call. = FALSE)
  if (paired && !nzchar(pair_id)) stop("配对分析必须指定 pair_id。", call. = FALSE)
  if (paired && length(categorical)) stop("当前配对单因素模块仅支持连续变量的配对 t 检验或配对 Wilcoxon 检验。", call. = FALSE)
  assert_columns(data, unique(c(group_variable, pair_id, continuous, categorical)), "group-comparison")
  group <- as.factor(data[[group_variable]])
  if (nlevels(droplevels(group)) < 2L) stop("分组变量有效水平少于 2 个。", call. = FALSE)

  continuous_results <- list(); posthoc_results <- list(); warnings <- character()
  for (variable in continuous) {
    if (paired) {
      frame <- paired_frame(data, variable, group_variable, pair_id)
      if (nrow(frame) < 3L) { warnings <- c(warnings, paste0(variable, " 的完整配对不足，未执行检验。")); next }
      difference <- frame$second - frame$first
      use_wilcoxon <- method_requested %in% c("wilcoxon", "nonparametric", "paired-wilcoxon")
      if (use_wilcoxon) {
        test <- stats::wilcox.test(frame$second, frame$first, paired = TRUE, exact = FALSE, conf.int = TRUE, conf.level = confidence_level)
        method <- "配对 Wilcoxon 符号秩检验"; statistic <- unname(test$statistic); estimate <- stats::median(difference)
        ci <- if (!is.null(test$conf.int)) unname(test$conf.int) else c(NA_real_, NA_real_)
        effect <- NA_real_; effect_type <- "rank-biserial (not estimated)"; effect_ci <- c(NA_real_, NA_real_)
      } else {
        test <- stats::t.test(frame$second, frame$first, paired = TRUE, conf.level = confidence_level)
        method <- "配对 t 检验"; statistic <- unname(test$statistic); estimate <- unname(test$estimate)
        ci <- unname(test$conf.int); effect <- mean(difference) / stats::sd(difference)
        effect_type <- "Cohen dz"
        effect_se <- sqrt(1 / nrow(frame) + effect^2 / (2 * max(1, nrow(frame) - 1)))
        effect_ci <- effect + c(-1, 1) * stats::qnorm(.975) * effect_se
      }
      summary_text <- paste0("", nrow(frame), " 对；平均差 ", sprintf("%.3f", mean(difference)), "；中位差 ", sprintf("%.3f", stats::median(difference)))
      continuous_results[[length(continuous_results) + 1L]] <- data.frame(
        variable = variable, label = configured_label(config, variable), n = nrow(frame), groups = 2L,
        paired = TRUE, group_summary = summary_text, method = method, statistic = statistic,
        estimate = estimate, conf_low = ci[[1]], conf_high = ci[[2]], effect_size = effect,
        effect_size_type = effect_type, effect_conf_low = effect_ci[[1]], effect_conf_high = effect_ci[[2]],
        p_value = test$p.value, stringsAsFactors = FALSE
      )
      next
    }
    frame <- data.frame(value = safe_numeric(data[[variable]]), group = group)
    frame <- frame[stats::complete.cases(frame), , drop = FALSE]; frame$group <- droplevels(frame$group)
    k <- nlevels(frame$group)
    if (nrow(frame) < 6L || k < 2L) { warnings <- c(warnings, paste0(variable, " 有效样本不足，未执行组间检验。")); next }
    group_values <- split(frame$value, frame$group)
    group_summary <- vapply(group_values, function(x) sprintf("%.3f ± %.3f；中位数 %.3f [%.3f, %.3f]", mean(x), stats::sd(x), stats::median(x), stats::quantile(x, .25), stats::quantile(x, .75)), character(1))
    summary_text <- paste(paste(names(group_summary), group_summary, sep = ": "), collapse = " | ")
    effect <- NA_real_; effect_type <- "not_applicable"; effect_ci <- c(NA_real_, NA_real_)
    if (k == 2L && method_requested %in% c("mann-whitney", "wilcoxon", "nonparametric")) {
      test <- stats::wilcox.test(value ~ group, data = frame, exact = FALSE, conf.int = TRUE, conf.level = confidence_level)
      method <- "Mann-Whitney U 检验"; statistic <- unname(test$statistic); estimate <- unname(test$estimate %||% NA_real_)
      ci <- if (!is.null(test$conf.int)) unname(test$conf.int) else c(NA_real_, NA_real_)
      effect_type <- "rank-biserial (not estimated)"
    } else if (k == 2L) {
      test <- stats::t.test(value ~ group, data = frame, var.equal = FALSE, conf.level = confidence_level)
      method <- "Welch t 检验"; statistic <- unname(test$statistic); estimate <- diff(unname(test$estimate)); ci <- unname(test$conf.int)
      x <- group_values[[1]]; y <- group_values[[2]]; effect <- hedges_g(x, y); effect_type <- "Hedges g"
      effect_ci <- effect_ci_from_g(effect, length(x), length(y))
    } else if (method_requested %in% c("kruskal-wallis", "kruskal", "nonparametric")) {
      test <- stats::kruskal.test(value ~ group, data = frame); method <- "Kruskal-Wallis 检验"; statistic <- unname(test$statistic)
      estimate <- NA_real_; ci <- c(NA_real_, NA_real_); effect <- max(0, (statistic - k + 1) / (nrow(frame) - k)); effect_type <- "epsilon squared"
    } else {
      test <- stats::oneway.test(value ~ group, data = frame, var.equal = FALSE); method <- "Welch ANOVA"; statistic <- unname(test$statistic)
      estimate <- NA_real_; ci <- c(NA_real_, NA_real_)
      aov_fit <- stats::aov(value ~ group, data = frame); effect <- summary(aov_fit)[[1]]["group", "Sum Sq"] / sum(summary(aov_fit)[[1]][, "Sum Sq"]); effect_type <- "eta squared"
    }
    continuous_results[[length(continuous_results) + 1L]] <- data.frame(
      variable = variable, label = configured_label(config, variable), n = nrow(frame), groups = k, paired = FALSE,
      group_summary = summary_text, method = method, statistic = statistic, estimate = estimate,
      conf_low = ci[[1]], conf_high = ci[[2]], effect_size = effect, effect_size_type = effect_type,
      effect_conf_low = effect_ci[[1]], effect_conf_high = effect_ci[[2]], p_value = test$p.value, stringsAsFactors = FALSE
    )
    if (k > 2L && posthoc_requested != "none") {
      use_kw <- method_requested %in% c("kruskal-wallis", "kruskal", "nonparametric") || posthoc_requested == "dunn"
      if (use_kw) {
        pairwise <- stats::pairwise.wilcox.test(frame$value, frame$group, p.adjust.method = posthoc_adjust, exact = FALSE)$p.value
        idx <- which(!is.na(pairwise), arr.ind = TRUE)
        for (row in seq_len(nrow(idx))) posthoc_results[[length(posthoc_results) + 1L]] <- data.frame(variable = variable, comparison = paste(rownames(pairwise)[idx[row, 1]], colnames(pairwise)[idx[row, 2]], sep = " vs "), method = "Pairwise Wilcoxon (Dunn-style)", estimate = NA_real_, conf_low = NA_real_, conf_high = NA_real_, p_adjusted = pairwise[idx[row, 1], idx[row, 2]], stringsAsFactors = FALSE)
      } else if (posthoc_requested == "tukey") {
        tukey <- stats::TukeyHSD(stats::aov(value ~ group, data = frame))$group
        for (name in rownames(tukey)) posthoc_results[[length(posthoc_results) + 1L]] <- data.frame(variable = variable, comparison = name, method = "Tukey HSD", estimate = tukey[name, "diff"], conf_low = tukey[name, "lwr"], conf_high = tukey[name, "upr"], p_adjusted = tukey[name, "p adj"], stringsAsFactors = FALSE)
      } else {
        levels <- levels(frame$group)
        for (pair in utils::combn(levels, 2L, simplify = FALSE)) {
          sub <- frame[frame$group %in% pair, , drop = FALSE]; pair_test <- stats::t.test(value ~ group, data = sub, var.equal = FALSE, conf.level = confidence_level)
          posthoc_results[[length(posthoc_results) + 1L]] <- data.frame(variable = variable, comparison = paste(pair, collapse = " vs "), method = "Pairwise Welch t", estimate = diff(unname(pair_test$estimate)), conf_low = pair_test$conf.int[[1]], conf_high = pair_test$conf.int[[2]], p_adjusted = pair_test$p.value, stringsAsFactors = FALSE)
        }
      }
    }
  }
  continuous_table <- if (length(continuous_results)) do.call(rbind, continuous_results) else data.frame(variable = character(), label = character(), n = integer(), groups = integer(), paired = logical(), group_summary = character(), method = character(), statistic = numeric(), estimate = numeric(), conf_low = numeric(), conf_high = numeric(), effect_size = numeric(), effect_size_type = character(), effect_conf_low = numeric(), effect_conf_high = numeric(), p_value = numeric())
  continuous_table$p_adjusted <- if (nrow(continuous_table)) stats::p.adjust(continuous_table$p_value, method = as.character(config$data_handling$multiple_testing$method %||% "holm")) else numeric()
  posthoc_table <- if (length(posthoc_results)) do.call(rbind, posthoc_results) else data.frame(variable = character(), comparison = character(), method = character(), estimate = numeric(), conf_low = numeric(), conf_high = numeric(), p_adjusted = numeric())
  if (nrow(posthoc_table) && any(grepl("Pairwise Welch", posthoc_table$method))) posthoc_table$p_adjusted <- stats::p.adjust(posthoc_table$p_adjusted, method = posthoc_adjust)

  categorical_results <- list()
  for (variable in categorical) {
    frame <- data.frame(value = as.factor(data[[variable]]), group = group); frame <- frame[stats::complete.cases(frame), , drop = FALSE]
    contingency <- table(droplevels(frame$value), droplevels(frame$group))
    if (nrow(contingency) < 2L || ncol(contingency) < 2L) { warnings <- c(warnings, paste0(variable, " 的列联表维度不足，未执行检验。")); next }
    chi <- suppressWarnings(stats::chisq.test(contingency, correct = FALSE)); sparse <- any(chi$expected < 5)
    exact <- if (sparse) tryCatch(stats::fisher.test(contingency), error = function(e) stats::fisher.test(contingency, simulate.p.value = TRUE, B = 5000)) else NULL
    method <- if (!sparse) "Pearson 卡方检验" else if (isTRUE(exact$simulate.p.value)) "Fisher Monte Carlo 检验" else "Fisher 精确检验"
    p_value <- if (sparse) exact$p.value else chi$p.value; statistic <- if (sparse) NA_real_ else unname(chi$statistic); total <- sum(contingency)
    categorical_results[[length(categorical_results) + 1L]] <- data.frame(variable = variable, label = configured_label(config, variable), n = total, rows = nrow(contingency), columns = ncol(contingency), method = method, statistic = statistic, cramers_v = sqrt(unname(chi$statistic) / (total * min(nrow(contingency) - 1L, ncol(contingency) - 1L))), p_value = p_value, sparse_expected_cells = sum(chi$expected < 5), stringsAsFactors = FALSE)
  }
  categorical_table <- if (length(categorical_results)) do.call(rbind, categorical_results) else data.frame(variable = character(), label = character(), n = integer(), rows = integer(), columns = integer(), method = character(), statistic = numeric(), cramers_v = numeric(), p_value = numeric(), sparse_expected_cells = integer())
  categorical_table$p_adjusted <- if (nrow(categorical_table)) stats::p.adjust(categorical_table$p_value, method = as.character(config$data_handling$multiple_testing$method %||% "holm")) else numeric()
  tables <- list(
    write_result_table(context, "group-comparison", "01_连续变量组间比较", "连续变量单因素组间比较", continuous_table, c(paste0("连续变量统一报告效应量及可用的 ", confidence_level * 100, "% 区间；配对分析仅使用完整配对。"))),
    write_result_table(context, "group-comparison", "02_分类变量组间比较", "分类变量单因素组间比较", categorical_table, c("期望频数不足时改用 Fisher 精确检验或 Monte Carlo 近似。")),
    write_result_table(context, "group-comparison", "03_事后比较", "连续变量事后比较", posthoc_table, c("事后比较仅在方案中明确启用；成对比较 P 值按指定方法校正。"))
  )
  new_module_result("group-comparison", "univariate-group-comparison", started_at, tables = tables, warnings = unique(warnings), limitations = c("单因素分析未控制潜在混杂，不能替代多变量模型。", "效应量置信区间在不适用时明确标记为缺失，不以显著性替代区间估计。"), narrative = c(paste0("以 ", group_variable, " 为分组变量完成已确认的单因素比较。")), sample = list(n_input = nrow(data), group_variable = group_variable, paired = paired, pair_id = if (paired) pair_id else NULL), random_seed = context$random_seed)
}
