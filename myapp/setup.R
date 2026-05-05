# AutoXP3 — first-time environment setup
# Run this once after cloning:
#   Rscript setup.R

message("Installing renv...")
if (!requireNamespace("renv", quietly = TRUE)) {
  install.packages("renv", repos = "https://cloud.r-project.org")
}

message("Initialising project library...")
renv::init(bare = TRUE)   # create renv/ without auto-scanning

message("Installing required packages...")
renv::install(c("shiny", "readxl", "writexl"))

message("Saving lockfile...")
renv::snapshot()

message("Done. Start the app with:  Rscript -e \"shiny::runApp('.')\"")
