`%||%` <- function(x, y) {
  if (is.null(x) || length(x) == 0L) y else x
}

utc_now <- function() {
  format(as.POSIXct(Sys.time(), tz = "UTC"), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
}

module_parameters <- function(config, module_id) {
  parameters <- config$analysis$parameters %||% list()
  parameters[[module_id]] %||% list()
}

configured_label <- function(config, variable) {
  labels <- config$variables$labels %||% list()
  as.character(labels[[variable]] %||% variable)
}

assert_columns <- function(data, variables, module_id) {
  variables <- unique(as.character(variables))
  variables <- variables[nzchar(variables)]
  missing <- setdiff(variables, names(data))
  if (length(missing)) {
    stop(
      module_id, " 缺少配置变量：",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  invisible(variables)
}

analysis_subset <- function(data, variables) {
  variables <- unique(as.character(variables))
  frame <- data[, variables, drop = FALSE]
  keep <- stats::complete.cases(frame)
  list(
    data = frame[keep, , drop = FALSE],
    n_input = nrow(frame),
    n_complete = sum(keep),
    n_excluded_missing = sum(!keep)
  )
}

safe_numeric <- function(value) {
  if (is.factor(value)) value <- as.character(value)
  suppressWarnings(as.numeric(value))
}

safe_skewness <- function(x) {
  x <- x[is.finite(x)]
  if (length(x) < 3L) return(NA_real_)
  center <- mean(x)
  spread <- stats::sd(x)
  if (!is.finite(spread) || spread == 0) return(0)
  mean(((x - center) / spread)^3)
}

quote_name <- function(value) {
  paste0("`", gsub("`", "\\\\`", value, fixed = TRUE), "`")
}

build_formula <- function(outcome, predictors) {
  stats::as.formula(
    paste(quote_name(outcome), "~", paste(vapply(predictors, quote_name, character(1)), collapse = " + "))
  )
}

apply_reference_levels <- function(data, reference_levels) {
  if (is.null(reference_levels) || !length(reference_levels)) return(data)
  for (variable in names(reference_levels)) {
    if (!variable %in% names(data)) next
    reference <- as.character(reference_levels[[variable]])
    data[[variable]] <- as.factor(data[[variable]])
    if (reference %in% levels(data[[variable]])) {
      data[[variable]] <- stats::relevel(data[[variable]], ref = reference)
    } else {
      stop("参照水平不存在：", variable, " = ", reference, call. = FALSE)
    }
  }
  data
}

relative_path <- function(path, root) {
  path_normal <- normalizePath(path, winslash = "/", mustWork = FALSE)
  root_normal <- normalizePath(root, winslash = "/", mustWork = FALSE)
  prefix <- paste0(root_normal, "/")
  if (startsWith(tolower(path_normal), tolower(prefix))) {
    return(substring(path_normal, nchar(prefix) + 1L))
  }
  path_normal
}

figure_contract_settings <- function(config) {
  reporting <- config$reporting %||% list()
  contract <- reporting$figure_contract %||% list()
  template <- tolower(as.character(contract$template %||% "medical-academic-v1"))
  if (!template %in% c("medical-academic-v1", "custom")) {
    stop("不支持的 R 图形模板：", template, call. = FALSE)
  }
  formats <- contract$formats %||% reporting$figure_formats %||% c("png")
  formats <- unique(tolower(as.character(formats)))
  allowed <- c("png", "svg", "pdf", "tiff")
  unsupported <- setdiff(formats, allowed)
  if (length(unsupported)) {
    stop(
      "不支持的图形格式：", paste(unsupported, collapse = ", "),
      call. = FALSE
    )
  }
  list(
    template = template,
    profile = tolower(as.character(contract$profile %||% "analysis")),
    backend = toupper(as.character(contract$backend %||% "R")),
    formats = formats,
    width_mm = as.numeric(contract$width_mm %||% 183),
    height_mm = as.numeric(contract$height_mm %||% 120),
    dpi = as.integer(contract$dpi %||% 300L),
    require_source_data = isTRUE(contract$require_source_data %||% TRUE),
    require_statistics_metadata = isTRUE(
      contract$require_statistics_metadata %||% TRUE
    ),
    require_editable_text = isTRUE(
      contract$require_editable_text %||% FALSE
    ),
    font_family = if (identical(template, "medical-academic-v1")) {
      resolve_medical_figure_font()
    } else {
      "sans"
    }
  )
}

medical_figure_palette <- function() {
  c(
    control = "#707070",
    intervention_a = "#2B6CB0",
    intervention_b = "#D97706",
    intervention_c = "#2F855A",
    intervention_d = "#805AD5",
    intervention_e = "#C53030",
    intervention_f = "#0F766E",
    neutral = "#707070",
    accent = "#2B6CB0",
    warning = "#D97706"
  )
}

medical_figure_colors <- function(n, alpha = 1, labels = NULL) {
  n <- as.integer(n)
  if (!is.finite(n) || n < 1L) return(character())
  palette <- medical_figure_palette()
  preferred <- c("control", "intervention_a", "intervention_b", "intervention_c", "intervention_d", "intervention_e", "intervention_f")
  if (!is.null(labels) && length(labels) == n) {
    keys <- tolower(gsub("[^a-z0-9]+", "_", as.character(labels)))
    colors <- unname(palette[keys])
    missing <- is.na(colors)
    if (any(missing)) colors[missing] <- unname(palette[preferred][seq_len(sum(missing))])
  } else {
    colors <- unname(palette[preferred][seq_len(min(n, length(preferred)))])
    if (n > length(colors)) colors <- rep(colors, length.out = n)
  }
  if (!identical(as.numeric(alpha), 1)) {
    colors <- grDevices::adjustcolor(colors, alpha.f = as.numeric(alpha))
  }
  colors
}

resolve_medical_figure_font <- function() {
  candidates <- c(
    "Microsoft YaHei", "Microsoft JhengHei", "STSong", "SimSun", "Arial"
  )
  if (requireNamespace("systemfonts", quietly = TRUE)) {
    installed <- unique(as.character(systemfonts::system_fonts()$family))
    available <- candidates[candidates %in% installed]
    if (length(available)) return(available[[1L]])
  }
  "Arial"
}

medical_figure_theme <- function(
  base_size = 7, base_family = resolve_medical_figure_font()
) {
  if (!requireNamespace("ggplot2", quietly = TRUE)) {
    stop("medical-academic-v1 需要 R 包 ggplot2。", call. = FALSE)
  }
  ggplot2::theme_classic(base_size = base_size, base_family = base_family) +
    ggplot2::theme(
      axis.line = ggplot2::element_line(linewidth = .35, colour = "black"),
      axis.ticks = ggplot2::element_line(linewidth = .35, colour = "black"),
      axis.text = ggplot2::element_text(size = base_size - .6, colour = "black"),
      axis.title = ggplot2::element_text(size = base_size),
      legend.text = ggplot2::element_text(size = base_size - .8),
      legend.title = ggplot2::element_text(size = base_size - .4),
      strip.text = ggplot2::element_text(size = base_size - .2, face = "bold"),
      plot.title = ggplot2::element_text(size = base_size + .8, face = "bold"),
      plot.subtitle = ggplot2::element_text(size = base_size - .4),
      plot.caption = ggplot2::element_text(
        size = base_size - 1.2, colour = "#4A4A4A", hjust = 0
      ),
      plot.tag = ggplot2::element_text(size = base_size + 1.2, face = "bold"),
      panel.grid = ggplot2::element_blank(),
      plot.margin = ggplot2::margin(4, 5, 4, 4, unit = "pt")
    )
}

apply_medical_figure_template <- function(plot, base_size = 7) {
  if (!inherits(plot, c("gg", "ggplot", "patchwork"))) {
    stop("apply_medical_figure_template 需要 ggplot 或 patchwork 对象。", call. = FALSE)
  }
  plot + medical_figure_theme(base_size = base_size)
}

apply_medical_base_figure_template <- function(settings, multi_panel = FALSE) {
  if (!is.list(settings)) {
    stop("基础图形模板设置必须为 list。", call. = FALSE)
  }
  graphics::par(
    family = settings$font_family %||% "Arial",
    bg = "white",
    fg = "black",
    col.axis = "black",
    col.lab = "black",
    col.main = "black",
    bty = "l",
    las = 1,
    mgp = c(2.2, .65, 0),
    tcl = -.25,
    cex = if (isTRUE(multi_panel)) .82 else .9,
    cex.axis = if (isTRUE(multi_panel)) .78 else .86,
    cex.lab = if (isTRUE(multi_panel)) .82 else .9,
    cex.main = if (isTRUE(multi_panel)) .86 else .94
  )
  invisible(settings)
}

open_r_figure_device <- function(
  path, format, width_in, height_in, dpi, font_family = "Arial"
) {
  switch(
    format,
    png = grDevices::png(
      path, width = width_in, height = height_in,
      units = "in", res = dpi, type = "cairo", family = font_family
    ),
    svg = grDevices::svg(
      path, width = width_in, height = height_in,
      onefile = TRUE, family = font_family
    ),
    pdf = {
      if (isTRUE(capabilities("cairo"))) {
        grDevices::cairo_pdf(
          path, width = width_in, height = height_in,
          onefile = TRUE, family = font_family
        )
      } else {
        grDevices::pdf(
          path, width = width_in, height = height_in,
          onefile = TRUE, family = font_family
        )
      }
    },
    tiff = grDevices::tiff(
      path, width = width_in, height = height_in,
      units = "in", res = dpi, compression = "lzw", type = "cairo", family = font_family
    ),
    stop("不支持的 R 图形设备：", format, call. = FALSE)
  )
}

export_r_figure <- function(
  config,
  context,
  file_stem,
  plot_function,
  width_mm = NULL,
  height_mm = NULL
) {
  settings <- figure_contract_settings(config)
  if (!identical(settings$backend, "R")) {
    stop("统计图形必须由 R 后端生成。", call. = FALSE)
  }
  if (!is.function(plot_function)) {
    stop("plot_function 必须是可执行的 R 绘图函数。", call. = FALSE)
  }
  width_mm <- as.numeric(width_mm %||% settings$width_mm)
  height_mm <- as.numeric(height_mm %||% settings$height_mm)
  width_in <- width_mm / 25.4
  height_in <- height_mm / 25.4
  exports <- list()
  for (format in settings$formats) {
    path <- file.path(context$module_output_dir, paste0(file_stem, ".", format))
    device_open <- FALSE
    old_par <- NULL
    tryCatch(
      {
        open_r_figure_device(
          path, format, width_in, height_in, settings$dpi,
          settings$font_family
        )
        device_open <- TRUE
        old_par <- graphics::par(no.readonly = TRUE)
        apply_medical_base_figure_template(settings)
        plot_function()
      },
      finally = {
        if (!is.null(old_par) && grDevices::dev.cur() > 1L) {
          try(graphics::par(old_par), silent = TRUE)
        }
        if (device_open && grDevices::dev.cur() > 1L) {
          grDevices::dev.off()
        }
      }
    )
    exports[[length(exports) + 1L]] <- list(
      format = format,
      path = relative_path(path, context$run_dir),
      editable_text = format %in% c("svg", "pdf"),
      width_mm = width_mm,
      height_mm = height_mm,
      dpi = if (format %in% c("png", "tiff")) settings$dpi else NULL,
      template = settings$template,
      font_family = settings$font_family
    )
  }
  exports
}

write_figure_source_data <- function(context, figure_id, data) {
  if (!is.data.frame(data)) {
    stop("图形 Source Data 必须是 data.frame。", call. = FALSE)
  }
  source_dir <- file.path(context$module_output_dir, "source_data")
  dir.create(source_dir, recursive = TRUE, showWarnings = FALSE)
  path <- file.path(source_dir, paste0(figure_id, "_source_data.csv"))
  utils::write.csv(
    data, path, row.names = FALSE, na = "", fileEncoding = "UTF-8"
  )
  relative_path(path, context$run_dir)
}

new_figure_object <- function(
  figure_id,
  title,
  exports,
  source_data_path,
  conclusion,
  evidence_role,
  statistics,
  source_module
) {
  required_statistics <- c(
    "n_definition",
    "biological_replicates",
    "technical_replicates",
    "center_statistic",
    "interval",
    "test",
    "multiple_comparison_correction"
  )
  missing_statistics <- setdiff(required_statistics, names(statistics))
  if (length(missing_statistics)) {
    stop(
      "图形统计元数据缺少字段：",
      paste(missing_statistics, collapse = ", "),
      call. = FALSE
    )
  }
  if (!length(exports)) stop("图形至少需要一个 R 导出文件。", call. = FALSE)
  preview_index <- which(vapply(
    exports,
    function(item) identical(item$format, "png"),
    logical(1)
  ))
  if (!length(preview_index)) preview_index <- 1L
  preview_path <- exports[[preview_index[[1]]]]$path
  list(
    figure_id = figure_id,
    title = title,
    path = preview_path,
    preview_path = preview_path,
    generated_by = "R",
    exports = exports,
    source_data_path = source_data_path,
    conclusion = conclusion,
    evidence_role = evidence_role,
    statistics = statistics,
    source_module = source_module,
    template = exports[[1L]]$template %||% "custom"
  )
}

ascii_only_column <- function(x) {
  values <- unique(as.character(x[!is.na(x)]))
  if (!length(values)) return(FALSE)
  all(grepl("^[\\x00-\\x7F]*$", values, perl = TRUE))
}

journal_table_header <- function(name) {
  labels <- c(
    variable = "变量", label = "变量", level = "水平", term = "变量（或水平）",
    comparison = "比较", method = "统计方法", n = "n", n_display = "n",
    missing_n = "缺失，n", groups = "组数", rows = "行数", columns = "列数",
    estimate = "估计值", estimate_log_odds = "估计值（log odds）",
    coefficient = "相关系数", std_error = "标准误", statistic = "统计量",
    effect_size = "效应量", effect_size_type = "效应量类型", cramers_v = "Cramér’s V",
    p_value = "P 值", p_adjusted = "校正后 P 值", group_summary = "各组描述统计",
    inference = "推断方法", r_squared = "R²", adjusted_r_squared = "调整后 R²",
    residual_sd = "残差标准差", f_statistic = "F 统计量", df_model = "模型自由度",
    df_residual = "残差自由度", model_p_value = "模型 P 值", events = "事件数",
    non_events = "非事件数", odds_ratio = "OR", hazard_ratio = "HR", auc = "AUC",
    brier_score = "Brier 分数", estimate_ci = "估计值（95% CI）",
    coefficient_ci = "相关系数（95% CI）", effect_size_ci = "效应量（95% CI）",
    odds_ratio_ci = "OR（95% CI）", hazard_ratio_ci = "HR（95% CI）"
  )
  value <- unname(labels[name])
  if (!length(value) || is.na(value)) gsub("_", " ", name) else value
}

format_table_p_value <- function(value) {
  number <- safe_numeric(value)
  if (!is.finite(number)) return("")
  if (number < 0.001) return("<0.001")
  formatC(number, format = "f", digits = 3)
}

format_table_scalar <- function(value, column) {
  text <- trimws(as.character(value %||% ""))
  if (!nzchar(text) || is.na(value)) return("")
  if (toupper(text) %in% c("TRUE", "FALSE")) return(if (toupper(text) == "TRUE") "是" else "否")
  if (column %in% c("p_value", "p_adjusted", "model_p_value")) return(format_table_p_value(value))
  number <- safe_numeric(value)
  if (!is.finite(number)) return(text)
  if (column %in% c("n", "n_display", "missing_n", "groups", "rows", "columns", "events", "non_events", "parameters", "df_model", "df_residual")) {
    return(formatC(round(number), format = "f", digits = 0))
  }
  digits <- if (column %in% c("coefficient", "effect_size", "cramers_v", "r_squared", "adjusted_r_squared", "auc", "brier_score")) 3 else 2
  if (column %in% c("odds_ratio", "hazard_ratio") && abs(number) < 0.01) digits <- 3
  formatC(number, format = "f", digits = digits)
}

format_table_ci <- function(estimate, lower, upper, estimate_column) {
  estimate_text <- format_table_scalar(estimate, estimate_column)
  lower_text <- format_table_scalar(lower, estimate_column)
  upper_text <- format_table_scalar(upper, estimate_column)
  if (nzchar(lower_text) && nzchar(upper_text)) {
    return(paste0(estimate_text, "（", lower_text, "–", upper_text, "）"))
  }
  estimate_text
}

combine_table_ci_columns <- function(data, point, lower, upper, combined) {
  required <- c(point, lower, upper)
  if (!all(required %in% names(data))) return(data)
  has_ci <- any(is.finite(suppressWarnings(as.numeric(data[[lower]]))) & is.finite(suppressWarnings(as.numeric(data[[upper]]))))
  if (!has_ci) return(data)
  data[[combined]] <- mapply(
    format_table_ci, data[[point]], data[[lower]], data[[upper]],
    MoreArgs = list(estimate_column = point), USE.NAMES = FALSE
  )
  original_names <- names(data)
  ordered_names <- character()
  for (name in original_names) {
    if (identical(name, point)) ordered_names <- c(ordered_names, combined)
    if (!name %in% c(point, lower, upper, combined)) ordered_names <- c(ordered_names, name)
  }
  data[, ordered_names, drop = FALSE]
}

table_variable_label <- function(config, variable) {
  label <- configured_label(config, variable)
  units <- config$variables$units %||% list()
  unit <- as.character(units[[variable]] %||% "")
  if (nzchar(unit) && !identical(label, variable)) paste0(label, "（", unit, "）") else label
}

render_journal_term <- function(value, config = list()) {
  term <- trimws(as.character(value %||% ""))
  if (!nzchar(term)) return("")
  if (identical(term, "(Intercept)")) return("截距")

  variables <- config$variables %||% list()
  labels <- variables$labels %||% list()
  categorical <- unique(as.character(unlist(variables$categorical %||% character(), use.names = FALSE)))
  categorical <- categorical[nzchar(categorical)]
  if (length(categorical)) {
    categorical <- categorical[order(nchar(categorical), decreasing = TRUE)]
    for (variable in categorical) {
      if (identical(term, variable)) return(table_variable_label(config, variable))
      if (startsWith(term, variable)) {
        level <- substring(term, nchar(variable) + 1L)
        if (nzchar(level)) return(paste0(table_variable_label(config, variable), "：", level))
      }
    }
  }
  if (term %in% names(labels)) return(table_variable_label(config, term))
  term
}

reference_level_note <- function(config, data) {
  if (!"term" %in% names(data)) return(character())
  variables <- config$variables %||% list()
  categorical <- unique(as.character(unlist(variables$categorical %||% character(), use.names = FALSE)))
  reference_levels <- variables$reference_levels %||% list()
  entries <- vapply(categorical, function(variable) {
    reference <- as.character(reference_levels[[variable]] %||% "")
    if (!nzchar(reference)) return("")
    paste0(table_variable_label(config, variable), "=", reference)
  }, character(1))
  entries <- entries[nzchar(entries)]
  if (!length(entries)) character() else paste0("分类自变量的参照水平：", paste(entries, collapse = "；"), "。")
}

present_journal_table <- function(data, config = list()) {
  data <- as.data.frame(data, stringsAsFactors = FALSE, check.names = FALSE)
  if (all(c("variable", "label") %in% names(data)) && any(nzchar(trimws(as.character(data$label))))) {
    data$variable <- NULL
  }
  for (spec in list(
    c("odds_ratio", "or_conf_low", "or_conf_high", "odds_ratio_ci"),
    c("hazard_ratio", "hr_conf_low", "hr_conf_high", "hazard_ratio_ci"),
    c("estimate", "conf_low", "conf_high", "estimate_ci"),
    c("coefficient", "conf_low", "conf_high", "coefficient_ci"),
    c("effect_size", "effect_conf_low", "effect_conf_high", "effect_size_ci")
  )) {
    data <- combine_table_ci_columns(data, spec[[1]], spec[[2]], spec[[3]], spec[[4]])
  }
  original_names <- names(data)
  for (name in original_names) {
    if (grepl("_ci$", name)) next
    if (name %in% c("term", "variable")) {
      data[[name]] <- vapply(data[[name]], render_journal_term, character(1), config = config)
    } else {
      data[[name]] <- vapply(data[[name]], format_table_scalar, character(1), column = name)
    }
  }
  names(data) <- vapply(original_names, journal_table_header, character(1))
  data
}

write_three_line_xlsx <- function(data, path, title, footnotes = character(), config = list()) {
  if (!requireNamespace("openxlsx2", quietly = TRUE)) {
    stop("写入 XLSX 需要 R 包 openxlsx2。", call. = FALSE)
  }
  presentation_data <- present_journal_table(data, config = config)
  workbook <- openxlsx2::wb_workbook(creator = "medical-analysis-orchestrator")
  workbook <- openxlsx2::wb_add_worksheet(
    workbook, "结果", grid_lines = FALSE, has_drawing = FALSE
  )
  column_count <- max(1L, ncol(presentation_data))
  last_column <- openxlsx2::int2col(column_count)
  title_dims <- paste0("A1:", last_column, "1")
  workbook <- openxlsx2::wb_add_data(
    workbook, "结果", title, start_row = 1L, start_col = 1L, col_names = FALSE
  )
  if (column_count > 1L) {
    workbook <- openxlsx2::wb_merge_cells(workbook, "结果", dims = title_dims)
  }
  workbook <- openxlsx2::wb_add_font(
    workbook, "结果", dims = title_dims, name = "宋体", size = 12, bold = TRUE
  )
  workbook <- openxlsx2::wb_add_cell_style(
    workbook, "结果", dims = title_dims, horizontal = "center", vertical = "center"
  )

  start_row <- 3L
  workbook <- openxlsx2::wb_add_data(
    workbook, "结果", presentation_data, start_row = start_row, start_col = 1L, col_names = TRUE
  )
  header_dims <- paste0("A", start_row, ":", last_column, start_row)
  workbook <- openxlsx2::wb_add_font(
    workbook, "结果", dims = header_dims, name = "宋体", size = 10.5, bold = TRUE
  )
  workbook <- openxlsx2::wb_add_cell_style(
    workbook, "结果", dims = header_dims,
    horizontal = "center", vertical = "center", wrap_text = TRUE
  )
  workbook <- openxlsx2::wb_add_border(
    workbook, "结果", dims = header_dims,
    top_border = "medium", bottom_border = "thin",
    left_border = NULL, right_border = NULL
  )

  if (nrow(presentation_data)) {
    body_first <- start_row + 1L
    body_last <- start_row + nrow(presentation_data)
    body_dims <- paste0("A", body_first, ":", last_column, body_last)
    workbook <- openxlsx2::wb_add_font(
      workbook, "结果", dims = body_dims, name = "宋体", size = 10.5
    )
    workbook <- openxlsx2::wb_add_cell_style(
      workbook, "结果", dims = body_dims, vertical = "center", wrap_text = TRUE
    )
    first_column_dims <- paste0("A", body_first, ":A", body_last)
    workbook <- openxlsx2::wb_add_cell_style(
      workbook, "结果", dims = first_column_dims, horizontal = "left", update = TRUE
    )
    if (column_count > 1L) {
      value_column_dims <- paste0("B", body_first, ":", last_column, body_last)
      workbook <- openxlsx2::wb_add_cell_style(
        workbook, "结果", dims = value_column_dims, horizontal = "center", update = TRUE
      )
    }
    latin_columns <- which(vapply(
      presentation_data,
      function(column) is.numeric(column) || is.integer(column) || ascii_only_column(column),
      logical(1)
    ))
    if (length(latin_columns)) {
      for (column_index in latin_columns) {
        column_name <- openxlsx2::int2col(column_index)
        latin_dims <- paste0(column_name, body_first, ":", column_name, body_last)
        workbook <- openxlsx2::wb_add_font(
          workbook, "结果", dims = latin_dims,
          name = "Times New Roman", size = 10.5
        )
      }
    }
    bottom_dims <- paste0("A", body_last, ":", last_column, body_last)
    workbook <- openxlsx2::wb_add_border(
      workbook, "结果", dims = bottom_dims,
      top_border = NULL, bottom_border = "medium",
      left_border = NULL, right_border = NULL, update = TRUE
    )
  }

  if (length(footnotes)) {
    note_row <- start_row + nrow(presentation_data) + 2L
    for (index in seq_along(footnotes)) {
      current_note_row <- note_row + index - 1L
      workbook <- openxlsx2::wb_add_data(
        workbook, "结果", paste0("注：", footnotes[[index]]),
        start_row = current_note_row, start_col = 1L, col_names = FALSE
      )
      if (column_count > 1L) {
        workbook <- openxlsx2::wb_merge_cells(
          workbook, "结果",
          dims = paste0("A", current_note_row, ":", last_column, current_note_row)
        )
      }
    }
    note_dims <- paste0(
      "A", note_row, ":", last_column, note_row + length(footnotes) - 1L
    )
    workbook <- openxlsx2::wb_add_font(
      workbook, "结果", dims = note_dims, name = "宋体", size = 9
    )
    workbook <- openxlsx2::wb_add_cell_style(
      workbook, "结果", dims = note_dims, wrap_text = TRUE, vertical = "top"
    )
  }

  if (ncol(presentation_data)) {
    for (column_index in seq_len(ncol(presentation_data))) {
      values <- c(names(presentation_data)[[column_index]], as.character(presentation_data[[column_index]]))
      width <- min(40, max(10, max(nchar(values, type = "width"), na.rm = TRUE) + 2))
      workbook <- openxlsx2::wb_set_col_widths(
        workbook, "结果", cols = column_index, widths = width
      )
    }
  }
  workbook <- openxlsx2::wb_freeze_pane(
    workbook, "结果", first_active_row = start_row + 1L
  )
  workbook <- openxlsx2::wb_set_page_setup(
    workbook,
    "结果",
    orientation = if (column_count >= 6L) "landscape" else "portrait",
    scale = NULL,
    fit_to_width = 1L,
    fit_to_height = 0L,
    paper_size = 9L,
    print_title_rows = start_row,
    horizontal_centered = TRUE
  )
  openxlsx2::wb_save(workbook, path, overwrite = TRUE)
}

write_result_table <- function(context, module_id, table_id, title, data, footnotes = character()) {
  output_dir <- context$module_output_dir
  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
  csv_path <- file.path(output_dir, paste0(table_id, ".csv"))
  xlsx_path <- file.path(output_dir, paste0(table_id, ".xlsx"))
  utils::write.csv(data, csv_path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  journal_notes <- unique(c(footnotes, reference_level_note(context$config %||% list(), data)))
  write_three_line_xlsx(data, xlsx_path, title, journal_notes, config = context$config %||% list())
  list(
    table_id = table_id,
    title = title,
    csv_path = relative_path(csv_path, context$run_dir),
    xlsx_path = relative_path(xlsx_path, context$run_dir),
    n_rows = nrow(data),
    n_columns = ncol(data),
    columns = names(data),
    footnotes = as.list(footnotes),
    source_module = module_id
  )
}

new_module_result <- function(
  module_id,
  method_id,
  started_at,
  tables = list(),
  figures = list(),
  model_objects = list(),
  diagnostics = list(),
  warnings = character(),
  limitations = character(),
  narrative = character(),
  sample = list(),
  random_seed = NULL
) {
  list(
    schema_version = "1.1",
    module_id = module_id,
    method_id = method_id,
    status = if (length(warnings)) "completed_with_warnings" else "completed",
    started_at_utc = started_at,
    completed_at_utc = utc_now(),
    sample = sample,
    tables = tables,
    figures = figures,
    model_objects = model_objects,
    diagnostics = diagnostics,
    warnings = as.list(warnings),
    limitations = as.list(limitations),
    narrative = as.list(narrative),
    session_metadata = list(
      r_version = as.character(getRversion()),
      random_seed = random_seed
    )
  )
}
