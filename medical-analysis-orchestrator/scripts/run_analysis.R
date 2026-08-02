#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)

arg_value <- function(name, default = NULL) {
  index <- match(name, args)
  if (is.na(index) || index == length(args)) return(default)
  args[[index + 1L]]
}

config_path <- arg_value("--config")
data_path_arg <- arg_value("--data")
if (is.null(config_path)) {
  stop("Usage: Rscript run_analysis.R --config <analysis_plan.yml> [--data <clean.csv>]")
}
config_path <- normalizePath(config_path, winslash = "/", mustWork = TRUE)
script_argument <- grep("^--file=", commandArgs(), value = TRUE)[1]
script_dir <- dirname(normalizePath(
  sub("^--file=", "", script_argument),
  winslash = "/",
  mustWork = TRUE
))
skill_root <- dirname(script_dir)

required_core <- c("yaml", "jsonlite", "digest", "openxlsx2")
missing_core <- required_core[
  !vapply(required_core, requireNamespace, quietly = TRUE, FUN.VALUE = logical(1))
]
if (length(missing_core)) {
  stop(
    "Missing core packages: ", paste(missing_core, collapse = ", "),
    ". Run the approved package installer first."
  )
}

config <- yaml::read_yaml(config_path)
run_dir <- config$run$output_dir
if (is.null(run_dir) || !nzchar(run_dir)) run_dir <- dirname(config_path)
if (!grepl("^([A-Za-z]:[/\\\\]|/)", run_dir)) {
  run_dir <- file.path(dirname(config_path), run_dir)
}
run_dir <- normalizePath(run_dir, winslash = "/", mustWork = FALSE)
dir.create(run_dir, recursive = TRUE, showWarnings = FALSE)
log_dir <- file.path(run_dir, "99_运行记录")
dir.create(log_dir, recursive = TRUE, showWarnings = FALSE)

prepared_value <- data_path_arg
if (is.null(prepared_value) || !nzchar(prepared_value)) {
  prepared_value <- config$input$prepared_data_path
}
if (is.null(prepared_value) || !nzchar(prepared_value)) {
  prepared_value <- file.path(run_dir, "01_数据整理", "05_清洁分析数据.csv")
}
if (!grepl("^([A-Za-z]:[/\\\\]|/)", prepared_value)) {
  prepared_value <- file.path(run_dir, prepared_value)
}
prepared_path <- normalizePath(prepared_value, winslash = "/", mustWork = TRUE)
data <- utils::read.csv(
  prepared_path,
  check.names = FALSE,
  stringsAsFactors = FALSE,
  na.strings = c("", "NA"),
  fileEncoding = "UTF-8-BOM"
)

selected_modules <- config$analysis$modules
module_ids <- vapply(
  selected_modules,
  function(item) {
    if (is.character(item)) item else item$id
  },
  character(1)
)
if (!length(module_ids)) stop("No confirmed analysis modules were selected.")

shared_utils <- file.path(skill_root, "modules", "_shared", "module_utils.R")
if (!file.exists(shared_utils)) stop("Shared module utilities are missing.")

context_base <- list(
  run_id = config$run$run_id,
  run_dir = run_dir,
  input_path = normalizePath(config$input$path, winslash = "/", mustWork = TRUE),
  prepared_data_path = prepared_path,
  prepared_data_sha256 = digest::digest(
    file = prepared_path, algo = "sha256", serialize = FALSE
  ),
  random_seed = config$run$random_seed,
  skill_root = skill_root,
  data = data,
  logs_dir = log_dir
)
set.seed(context_base$random_seed)

results <- list()
execution_error <- NULL
for (module_id in module_ids) {
  descriptor_path <- file.path(skill_root, "modules", module_id, "module.yml")
  if (!file.exists(descriptor_path)) stop("Unknown module: ", module_id)
  descriptor <- yaml::read_yaml(descriptor_path)
  if (!identical(descriptor$status, "ready")) {
    stop("Module is not ready: ", module_id, " (", descriptor$status, ")")
  }
  entrypoint <- file.path(dirname(descriptor_path), descriptor$entrypoint)
  if (!file.exists(entrypoint)) stop("Ready module is missing entrypoint: ", entrypoint)
  module_output_dir <- file.path(run_dir, descriptor$output_dir)
  dir.create(module_output_dir, recursive = TRUE, showWarnings = FALSE)
  context <- context_base
  context$module_id <- module_id
  context$module_output_dir <- module_output_dir
  context$module_descriptor <- descriptor

  module_environment <- new.env(parent = globalenv())
  sys.source(shared_utils, envir = module_environment)
  sys.source(entrypoint, envir = module_environment)
  if (!exists("run_module", envir = module_environment, inherits = FALSE)) {
    stop("Module does not define run_module(config, context): ", module_id)
  }
  result <- tryCatch(
    module_environment$run_module(config, context),
    error = function(condition) {
      execution_error <<- list(
        module_id = module_id,
        message = conditionMessage(condition),
        class = class(condition)[1]
      )
      NULL
    }
  )
  if (is.null(result)) break
  results[[module_id]] <- result
  saveRDS(result, file.path(module_output_dir, paste0(module_id, "_result.rds")))
}

status_payload <- list(
  schema_version = "1.0",
  run_id = context_base$run_id,
  status = if (is.null(execution_error)) "completed" else "failed",
  completed_modules = names(results),
  failed_module = if (is.null(execution_error)) NULL else execution_error$module_id,
  error = execution_error,
  prepared_data_sha256 = context_base$prepared_data_sha256
)
jsonlite::write_json(
  status_payload,
  file.path(run_dir, "execution_status.json"),
  pretty = TRUE,
  auto_unbox = TRUE,
  null = "null"
)
saveRDS(results, file.path(run_dir, "analysis_results.rds"))
jsonlite::write_json(
  results,
  file.path(run_dir, "analysis_results.json"),
  pretty = TRUE,
  auto_unbox = TRUE,
  null = "null",
  na = "null"
)
writeLines(capture.output(sessionInfo()), file.path(run_dir, "sessionInfo.txt"))

package_specs <- list()
for (module_id in module_ids) {
  descriptor <- yaml::read_yaml(file.path(skill_root, "modules", module_id, "module.yml"))
  package_specs <- c(
    package_specs,
    descriptor$required_packages,
    descriptor$optional_packages
  )
}
package_names <- unique(c(
  required_core,
  vapply(
    package_specs,
    function(item) if (is.character(item)) item else item$name,
    character(1)
  )
))
figure_template_value <- config$reporting$figure_contract$template
if (is.null(figure_template_value) || !length(figure_template_value)) {
  figure_template_value <- "medical-academic-v1"
}
figure_template <- tolower(as.character(figure_template_value))
if (identical(figure_template, "medical-academic-v1")) {
  package_names <- unique(c(
    package_names, "ggplot2", "patchwork", "ragg", "svglite", "png"
  ))
}
installed <- installed.packages()
package_table <- data.frame(
  package = package_names,
  installed = package_names %in% rownames(installed),
  version = vapply(
    package_names,
    function(package_name) {
      if (package_name %in% rownames(installed)) {
        as.character(installed[package_name, "Version"])
      } else {
        NA_character_
      }
    },
    character(1)
  ),
  library = vapply(
    package_names,
    function(package_name) {
      if (package_name %in% rownames(installed)) {
        as.character(installed[package_name, "LibPath"])
      } else {
        NA_character_
      }
    },
    character(1)
  ),
  stringsAsFactors = FALSE
)
utils::write.csv(
  package_table,
  file.path(run_dir, "package_versions.csv"),
  row.names = FALSE,
  na = ""
)

if (!is.null(execution_error)) {
  stop(
    "Module execution failed in ", execution_error$module_id,
    ": ", execution_error$message
  )
}
cat("Analysis completed for run_id:", context_base$run_id, "\n")
