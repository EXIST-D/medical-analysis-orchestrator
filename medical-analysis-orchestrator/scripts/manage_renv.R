#!/usr/bin/env Rscript
# Create a run-local renv lock or restore it without modifying a system R library.

args <- commandArgs(trailingOnly = TRUE)
argument_value <- function(name, default = NULL) {
  index <- match(name, args)
  if (is.na(index) || index == length(args)) return(default)
  args[[index + 1L]]
}
mode <- tolower(argument_value("--mode", "off"))
project <- normalizePath(argument_value("--project", getwd()), winslash = "/", mustWork = FALSE)
library_path <- normalizePath(argument_value("--library", .libPaths()[[1]]), winslash = "/", mustWork = FALSE)
repository <- argument_value("--repository", "https://cloud.r-project.org")
packages_text <- argument_value("--packages", "")
status_path <- argument_value("--status", file.path(project, "runtime", "renv_status.json"))
lockfile <- file.path(project, "renv.lock")
dir.create(dirname(status_path), recursive = TRUE, showWarnings = FALSE)
dir.create(library_path, recursive = TRUE, showWarnings = FALSE)
.libPaths(unique(c(library_path, .libPaths())))

utc_now <- function() format(as.POSIXct(Sys.time(), tz = "UTC"), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
write_status <- function(status, message = NULL, details = list()) {
  payload <- c(list(
    schema_version = "1.0", generated_at_utc = utc_now(), mode = mode,
    status = status, project = project, lockfile = lockfile,
    library = library_path, message = message,
    renv_version = if (requireNamespace("renv", quietly = TRUE)) as.character(utils::packageVersion("renv")) else NULL
  ), details)
  jsonlite::write_json(payload, status_path, auto_unbox = TRUE, pretty = TRUE, null = "null")
}
if (mode %in% c("off", "false", "disabled")) {
  write_status("disabled", "renv is disabled by the confirmed runtime configuration")
  quit(status = 0L)
}
if (!mode %in% c("snapshot", "restore", "auto")) stop("Unsupported renv mode: ", mode, call. = FALSE)
if (!requireNamespace("renv", quietly = TRUE)) {
  install_result <- tryCatch({
    utils::install.packages("renv", lib = library_path, repos = repository, quiet = TRUE)
    TRUE
  }, error = function(e) {
    write_status("failed", paste0("renv installation failed: ", conditionMessage(e)))
    FALSE
  })
  if (!install_result || !requireNamespace("renv", quietly = TRUE)) {
    stop("Unable to install or load renv in the project R library.", call. = FALSE)
  }
}
packages <- strsplit(packages_text, ",", fixed = TRUE)[[1L]]
packages <- packages[nzchar(packages)]
if (mode == "restore") {
  if (!file.exists(lockfile)) {
    write_status("failed", "renv.lock does not exist; restore cannot proceed")
    stop("renv.lock does not exist for restore.", call. = FALSE)
  }
  restore_library <- file.path(project, "renv", "library")
  dir.create(restore_library, recursive = TRUE, showWarnings = FALSE)
  tryCatch({
    renv::restore(project = project, library = restore_library, lockfile = lockfile, prompt = FALSE)
    write_status("restored", "run-local renv library restored", list(restored_library = restore_library))
  }, error = function(e) {
    write_status("failed", paste0("renv restore failed: ", conditionMessage(e)))
    stop(e)
  })
} else {
  tryCatch({
    renv::snapshot(project = project, library = .libPaths(), lockfile = lockfile,
      packages = if (length(packages)) packages else NULL, prompt = FALSE)
    write_status("snapshotted", "renv.lock records the packages used by this run", list(packages = packages))
  }, error = function(e) {
    write_status("failed", paste0("renv snapshot failed: ", conditionMessage(e)))
    stop(e)
  })
}
