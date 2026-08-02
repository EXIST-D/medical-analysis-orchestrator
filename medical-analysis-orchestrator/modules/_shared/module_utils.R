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
    font_family = if (identical(template, "medical-academic-v1")) "Arial" else "sans"
  )
}

medical_figure_palette <- function() {
  c(
    control = "#707070",
    intervention_a = "#2B6CB0",
    intervention_b = "#D97706",
    neutral = "#707070",
    accent = "#2B6CB0",
    warning = "#D97706"
  )
}

medical_figure_theme <- function(base_size = 7, base_family = "Arial") {
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

open_r_figure_device <- function(path, format, width_in, height_in, dpi) {
  switch(
    format,
    png = grDevices::png(
      path, width = width_in, height = height_in,
      units = "in", res = dpi, type = "cairo"
    ),
    svg = grDevices::svg(
      path, width = width_in, height = height_in,
      onefile = TRUE, family = "Arial"
    ),
    pdf = {
      if (isTRUE(capabilities("cairo"))) {
        grDevices::cairo_pdf(
          path, width = width_in, height = height_in,
          onefile = TRUE, family = "Arial"
        )
      } else {
        grDevices::pdf(
          path, width = width_in, height = height_in,
          onefile = TRUE, family = "Arial"
        )
      }
    },
    tiff = grDevices::tiff(
      path, width = width_in, height = height_in,
      units = "in", res = dpi, compression = "lzw", type = "cairo"
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
    tryCatch(
      {
        open_r_figure_device(
          path, format, width_in, height_in, settings$dpi
        )
        device_open <- TRUE
        old_par <- graphics::par(no.readonly = TRUE)
        on.exit(graphics::par(old_par), add = TRUE)
        graphics::par(family = settings$font_family)
        plot_function()
      },
      finally = {
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
      dpi = if (format %in% c("png", "tiff")) settings$dpi else NULL
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
    source_module = source_module
  )
}

ascii_only_column <- function(x) {
  values <- unique(as.character(x[!is.na(x)]))
  if (!length(values)) return(FALSE)
  all(grepl("^[\\x00-\\x7F]*$", values, perl = TRUE))
}

write_three_line_xlsx <- function(data, path, title, footnotes = character()) {
  if (!requireNamespace("openxlsx2", quietly = TRUE)) {
    stop("写入 XLSX 需要 R 包 openxlsx2。", call. = FALSE)
  }
  workbook <- openxlsx2::wb_workbook(creator = "medical-analysis-orchestrator")
  workbook <- openxlsx2::wb_add_worksheet(
    workbook, "结果", grid_lines = FALSE, has_drawing = FALSE
  )
  column_count <- max(1L, ncol(data))
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
    workbook, "结果", data, start_row = start_row, start_col = 1L, col_names = TRUE
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

  if (nrow(data)) {
    body_first <- start_row + 1L
    body_last <- start_row + nrow(data)
    body_dims <- paste0("A", body_first, ":", last_column, body_last)
    workbook <- openxlsx2::wb_add_font(
      workbook, "结果", dims = body_dims, name = "宋体", size = 10.5
    )
    workbook <- openxlsx2::wb_add_cell_style(
      workbook, "结果", dims = body_dims, vertical = "center", wrap_text = TRUE
    )
    latin_columns <- which(vapply(
      data,
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
    note_row <- start_row + nrow(data) + 2L
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

  if (ncol(data)) {
    for (column_index in seq_len(ncol(data))) {
      values <- c(names(data)[[column_index]], as.character(data[[column_index]]))
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
  write_three_line_xlsx(data, xlsx_path, title, footnotes)
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
