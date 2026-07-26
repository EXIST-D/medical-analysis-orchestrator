#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)

arg_value <- function(name, default = NULL) {
  index <- match(name, args)
  if (is.na(index) || index == length(args)) {
    return(default)
  }
  args[[index + 1]]
}

json_string <- function(value) {
  value <- gsub("\\\\", "\\\\\\\\", as.character(value))
  value <- gsub("\"", "\\\\\"", value, fixed = TRUE)
  value <- gsub("\r", "\\\\r", value, fixed = TRUE)
  value <- gsub("\n", "\\\\n", value, fixed = TRUE)
  paste0("\"", value, "\"")
}

output_dir <- arg_value("--output", ".")
packages_arg <- arg_value("--packages", "")
library_path <- arg_value("--library", "")
packages <- trimws(strsplit(packages_arg, ",", fixed = TRUE)[[1]])
packages <- packages[nzchar(packages)]
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
if (nzchar(library_path)) {
  dir.create(library_path, recursive = TRUE, showWarnings = FALSE)
  .libPaths(unique(c(library_path, .libPaths())))
}

installed <- installed.packages()
package_rows <- lapply(packages, function(package_name) {
  is_installed <- package_name %in% rownames(installed)
  data.frame(
    package = package_name,
    installed = is_installed,
    version = if (is_installed) as.character(installed[package_name, "Version"]) else NA_character_,
    library = if (is_installed) as.character(installed[package_name, "LibPath"]) else NA_character_,
    stringsAsFactors = FALSE
  )
})
package_table <- if (length(package_rows)) do.call(rbind, package_rows) else data.frame(
  package = character(),
  installed = logical(),
  version = character(),
  library = character()
)
write.csv(
  package_table,
  file.path(output_dir, "package_versions.csv"),
  row.names = FALSE,
  na = ""
)

session_lines <- capture.output(sessionInfo())
writeLines(session_lines, file.path(output_dir, "sessionInfo.txt"), useBytes = TRUE)

lib_paths <- paste(vapply(.libPaths(), json_string, character(1)), collapse = ",")
missing <- package_table$package[!package_table$installed]
missing_json <- paste(vapply(missing, json_string, character(1)), collapse = ",")
environment_json <- paste0(
  "{\n",
  "  \"r_version\": ", json_string(as.character(getRversion())), ",\n",
  "  \"r_home\": ", json_string(R.home()), ",\n",
  "  \"platform\": ", json_string(R.version$platform), ",\n",
  "  \"library_paths\": [", lib_paths, "],\n",
  "  \"missing_packages\": [", missing_json, "]\n",
  "}\n"
)
writeLines(
  environment_json,
  file.path(output_dir, "r_probe.json"),
  useBytes = TRUE
)

cat("R environment probe completed\n")
