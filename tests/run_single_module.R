#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
arg_value <- function(name) {
  index <- match(name, args)
  if (is.na(index) || index == length(args)) stop("Missing argument: ", name)
  args[[index + 1L]]
}

skill_root <- normalizePath(arg_value("--skill-root"), winslash = "/", mustWork = TRUE)
module_id <- arg_value("--module")
config_path <- normalizePath(arg_value("--config"), winslash = "/", mustWork = TRUE)
data_path <- normalizePath(arg_value("--data"), winslash = "/", mustWork = TRUE)
run_dir <- normalizePath(arg_value("--run-dir"), winslash = "/", mustWork = FALSE)
dir.create(run_dir, recursive = TRUE, showWarnings = FALSE)
module_output_dir <- file.path(run_dir, module_id)
dir.create(module_output_dir, recursive = TRUE, showWarnings = FALSE)

for (package in c("jsonlite", "yaml", "openxlsx2", "digest")) {
  if (!requireNamespace(package, quietly = TRUE)) {
    stop("Missing matrix-test package: ", package)
  }
}
config <- jsonlite::fromJSON(config_path, simplifyVector = TRUE)
data <- utils::read.csv(
  data_path, check.names = FALSE, stringsAsFactors = FALSE,
  na.strings = c("", "NA"), fileEncoding = "UTF-8"
)
descriptor_path <- file.path(skill_root, "modules", module_id, "module.yml")
descriptor <- yaml::read_yaml(descriptor_path)
shared_path <- file.path(skill_root, "modules", "_shared", "module_utils.R")
entrypoint <- file.path(dirname(descriptor_path), descriptor$entrypoint)
environment <- new.env(parent = globalenv())
sys.source(shared_path, envir = environment)
sys.source(entrypoint, envir = environment)
context <- list(
  run_id = paste0("matrix_", module_id),
  run_dir = run_dir,
  input_path = data_path,
  prepared_data_path = data_path,
  prepared_data_sha256 = digest::digest(file = data_path, algo = "sha256", serialize = FALSE),
  random_seed = 20260803L,
  skill_root = skill_root,
  data = data,
  logs_dir = file.path(run_dir, "logs"),
  module_id = module_id,
  module_output_dir = module_output_dir,
  module_descriptor = descriptor
)
dir.create(context$logs_dir, recursive = TRUE, showWarnings = FALSE)
set.seed(context$random_seed)
result <- environment$run_module(config, context)
if (!identical(result$module_id, module_id)) stop("Module ID mismatch")
if (!result$status %in% c("completed", "completed_with_warnings")) stop("Module did not complete")
if (!length(result$tables)) stop("Module returned no tables")
jsonlite::write_json(
  result, file.path(run_dir, paste0(module_id, "_result.json")),
  pretty = TRUE, auto_unbox = TRUE, null = "null", na = "null"
)
cat("MATRIX_MODULE_PASS ", module_id, " ", result$method_id, "\n", sep = "")
