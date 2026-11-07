args <- commandArgs(trailingOnly = TRUE)
mode <- args[[1L]]
out <- args[[2L]]
stopifnot(mode %in% c("generate", "check"))
dir.create(out, recursive = TRUE, showWarnings = FALSE)
stopifnot(as.character(utils::packageVersion("roxygen2")) == "8.1.1")
capture.output(sessionInfo(), file = file.path(out, "R-session-info.txt"))
writeLines(system2("git", c("rev-parse", "HEAD"), stdout = TRUE),
           file.path(out, "source-sha.txt"))
stopifnot(!length(system2("git", c("diff", "--name-only"), stdout = TRUE)))

roxygen2::roxygenise(roclets = "rd")
changed <- system2("git", c("diff", "--name-only"), stdout = TRUE)
patch <- system2("git", c("diff", "--", "man/ddbs_write_dataset.Rd"), stdout = TRUE)
writeLines(patch, file.path(out, "generated-documentation.diff"))
file.copy("man/ddbs_write_dataset.Rd", out, overwrite = TRUE)
cat("BEGIN_GENERATED_DDBS_WRITE_DATASET_RD\n")
cat(readLines("man/ddbs_write_dataset.Rd"), sep = "\n")
cat("\nEND_GENERATED_DDBS_WRITE_DATASET_RD\n")
stopifnot(all(changed %in% "man/ddbs_write_dataset.Rd"))
if (mode == "check" && length(changed)) {
  stop("Generated help differs from the checked-in source")
}
