#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)

arg_value <- function(name, default = NULL) {
  index <- match(name, args)
  if (is.na(index) || index == length(args)) {
    return(default)
  }
  args[[index + 1]]
}

as_flag <- function(value) {
  tolower(as.character(value)) %in% c("1", "true", "yes")
}

packages_arg <- arg_value("--packages", "")
packages <- unique(trimws(strsplit(packages_arg, ",", fixed = TRUE)[[1]]))
packages <- packages[nzchar(packages)]
minimum_arg <- arg_value("--minimum-versions", "")
minimum_specs <- trimws(strsplit(minimum_arg, ";", fixed = TRUE)[[1]])
minimum_specs <- minimum_specs[nzchar(minimum_specs)]
minimum_versions <- setNames(rep("0", length(packages)), packages)
for (specification in minimum_specs) {
  parts <- strsplit(specification, "=", fixed = TRUE)[[1]]
  if (length(parts) >= 2L && nzchar(parts[[1]])) {
    minimum_versions[[parts[[1]]]] <- parts[[2]]
  }
}
library_path <- normalizePath(
  arg_value("--library", file.path(getwd(), ".r-library")),
  winslash = "/",
  mustWork = FALSE
)
repository <- arg_value("--repository", "https://cloud.r-project.org")
log_dir <- normalizePath(
  arg_value("--log-dir", file.path(getwd(), "logs")),
  winslash = "/",
  mustWork = FALSE
)
allow_install <- as_flag(arg_value("--allow-install", "false"))
dry_run <- as_flag(arg_value("--dry-run", "false"))

if (!allow_install) {
  stop(
    "Package installation is disabled. Re-run only after plan confirmation with ",
    "--allow-install true."
  )
}

system_library <- normalizePath(
  file.path(R.home(), "library"),
  winslash = "/",
  mustWork = FALSE
)
library_lower <- tolower(library_path)
system_lower <- tolower(system_library)
if (
  library_lower == system_lower ||
  startsWith(library_lower, paste0(system_lower, "/"))
) {
  stop("Refusing to install into the system R Library: ", library_path)
}

dir.create(library_path, recursive = TRUE, showWarnings = FALSE)
dir.create(log_dir, recursive = TRUE, showWarnings = FALSE)
.libPaths(unique(c(library_path, .libPaths())))

installed <- installed.packages()
records <- list()

for (package_name in packages) {
  already_installed <- package_name %in% rownames(installed)
  previous_version <- if (already_installed) {
    as.character(installed[package_name, "Version"])
  } else {
    NA_character_
  }
  minimum_version <- minimum_versions[[package_name]]
  version_satisfied <- already_installed &&
    utils::compareVersion(previous_version, minimum_version) >= 0
  status <- if (version_satisfied) "already_satisfied" else "pending"
  error <- NA_character_

  if (!version_satisfied && !dry_run) {
    status <- tryCatch(
      {
        install.packages(
          package_name,
          lib = library_path,
          repos = repository,
          dependencies = NA
        )
        if (requireNamespace(package_name, quietly = TRUE, lib.loc = library_path)) {
          "installed"
        } else {
          stop("Package was not available after install.packages")
        }
      },
      error = function(condition) {
        error <<- conditionMessage(condition)
        "failed"
      }
    )
  } else if (!version_satisfied && dry_run) {
    status <- "would_install"
  }

  current <- installed.packages(lib.loc = .libPaths())
  new_version <- if (package_name %in% rownames(current)) {
    as.character(current[package_name, "Version"])
  } else {
    NA_character_
  }
  records[[length(records) + 1]] <- data.frame(
    package = package_name,
    minimum_version = minimum_version,
    previous_version = previous_version,
    current_version = new_version,
    library = library_path,
    repository = repository,
    status = status,
    error = error,
    stringsAsFactors = FALSE
  )
}

result <- if (length(records)) do.call(rbind, records) else data.frame(
  package = character(),
  minimum_version = character(),
  previous_version = character(),
  current_version = character(),
  library = character(),
  repository = character(),
  status = character(),
  error = character()
)
timestamp <- format(Sys.time(), "%Y%m%dT%H%M%S")
log_path <- file.path(log_dir, paste0("package_install_", timestamp, ".csv"))
write.csv(result, log_path, row.names = FALSE, na = "")

failed <- result$status == "failed"
if (any(failed)) {
  stop(
    "Failed packages: ",
    paste(result$package[failed], collapse = ", "),
    ". See ",
    log_path
  )
}

cat("Package check/install completed. Log:", log_path, "\n")
