#!/usr/bin/env Rscript

source(file.path(getwd(), "modules", "_shared", "module_utils.R"), encoding = "UTF-8")

example <- data.frame(
  term = "groupintervention_b",
  estimate_log_odds = -1.107238478,
  std_error = 0.4167238937,
  statistic = -2.657007422,
  p_value = 0.007883770741,
  odds_ratio = 0.3304703031,
  or_conf_low = 0.1460213695,
  or_conf_high = 0.7479084847,
  stringsAsFactors = FALSE
)

rendered <- present_journal_table(example)
stopifnot(identical(
  names(rendered),
  c("变量（或水平）", "估计值（log odds）", "标准误", "统计量", "P 值", "OR（95% CI）")
))
stopifnot(identical(rendered[["P 值"]][[1]], "0.008"))
stopifnot(identical(rendered[["OR（95% CI）"]][[1]], "0.33（0.15–0.75）"))

configured <- list(variables = list(
  categorical = c("group"),
  labels = list(group = "治疗组"),
  reference_levels = list(group = "control")
))
configured_rendered <- present_journal_table(example, config = configured)
stopifnot(identical(configured_rendered[["变量（或水平）"]][[1]], "治疗组：intervention_b"))
stopifnot(identical(
  reference_level_note(configured, example),
  "分类自变量的参照水平：治疗组=control。"
))

cat("R table presentation contract passed\n")
