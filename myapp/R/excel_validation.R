# Excel upload validation for AutoXP3
#
# Purpose:
#   Validate the uploaded Excel template immediately at upload time,
#   and return a clear error message before downstream processing starts.
#
# Return value:
#   A list with:
#     - error: NULL if validation passed, otherwise a character error message
#     - sheets / normalized_sheets / i_def / i_data / def_raw / data_raw:
#       values reused by server.R after successful validation
#
# Main error categories handled here:
#   1. Workbook itself cannot be read
#   2. Definition/Data sheet missing or duplicated
#   3. Definition required columns missing
#   4. Definition rows invalid (blank Parameter, duplicate Parameter, invalid Type)
#   5. Required X/Y/id columns missing in Data
#   6. Data id invalid (blank / duplicate)
#   7. Continuous definition invalid (Min/Standard/Max/Interval)
#   8. Categorical definition invalid (no available levels)
#   9. Y Purpose blank
#  10. Unexpected extra columns in Data
#  11. Data numeric columns invalid (blank / non-numeric)
#  12. Data categorical columns invalid (blank)

validate_excel_upload <- function(path, normalize_sheet_name) {

  # Helper: standard return object for upload validation failure.
  # Corresponding error category:
  #   Common exit path used by all validation errors below.
  fail <- function(msg) {
    list(
      error = msg,
      sheets = NULL,
      normalized_sheets = NULL,
      i_def = integer(0),
      i_data = integer(0),
      def_raw = NULL,
      data_raw = NULL
    )
  }

  # Try to read workbook sheet names.
  # Corresponding error:
  #   "Failed to read the Excel workbook..."
  #   when the file is not a valid .xlsx or cannot be opened.
  sheets <- tryCatch(excel_sheets(path), error = function(e) NULL)
  if (is.null(sheets)) {
    return(fail("Failed to read the Excel workbook. Please check that the file is a valid .xlsx file."))
  }

  # Normalize sheet names (e.g. case/space-insensitive matching) and locate
  # the required Definition and Data sheets.
  ns <- normalize_sheet_name(sheets)
  i_def  <- which(ns %in% c("definition"))
  i_data <- which(ns %in% c("data"))

  # Corresponding error:
  #   "Excel must contain exactly one sheet named 'Definition'."
  # This covers both:
  #   - Definition sheet missing
  #   - Definition sheet duplicated
  if (length(i_def) != 1) {
    return(fail("Excel must contain exactly one sheet named 'Definition'."))
  }

  # Corresponding error:
  #   "Excel must contain exactly one sheet named 'Data'."
  # This covers both:
  #   - Data sheet missing
  #   - Data sheet duplicated
  if (length(i_data) != 1) {
    return(fail("Excel must contain exactly one sheet named 'Data'."))
  }

  # Read Definition and Data.
  # Corresponding errors:
  #   - "Failed to read the 'Definition' sheet."
  #   - "Failed to read the 'Data' sheet."
  def_raw <- tryCatch(read_excel(path, sheet = sheets[i_def[1]]), error = function(e) NULL)
  data_raw <- tryCatch(read_excel(path, sheet = sheets[i_data[1]]), error = function(e) NULL)

  if (is.null(def_raw)) return(fail("Failed to read the 'Definition' sheet."))
  if (is.null(data_raw)) return(fail("Failed to read the 'Data' sheet."))

  # Convert to plain data.frame for easier downstream checks.
  def <- as.data.frame(def_raw, stringsAsFactors = FALSE)
  dat <- as.data.frame(data_raw, stringsAsFactors = FALSE)

  # Check that Definition contains all required columns.
  # Corresponding error:
  #   "Definition sheet must contain columns: ..."
  required_cols <- c("Parameter", "Min", "Standard", "Max", "Type", "Interval", "Purpose")
  if (!all(required_cols %in% names(def))) {
    return(fail("Definition sheet must contain columns: Parameter, Min, Standard, Max, Type, Interval, Purpose"))
  }

  # Build a cleaned Definition table used only for validation.
  # row_no keeps the original Excel row index (header assumed on row 1),
  # so that error messages can point to the apparent Excel row.
  def2 <- data.frame(
    row_no        = seq_len(nrow(def)) + 1L,
    Parameter     = as.character(def$Parameter),
    Type          = tolower(trimws(as.character(def$Type))),
    Interval_raw  = as.character(def$Interval),
    Purpose       = as.character(def$Purpose),
    Min_raw       = as.character(def$Min),
    Standard_raw  = as.character(def$Standard),
    Max_raw       = as.character(def$Max),
    stringsAsFactors = FALSE
  )

  # Remove rows where Parameter is blank.
  # This is not itself an error. It allows users to have trailing empty rows.
  keep <- !is.na(def2$Parameter) & trimws(def2$Parameter) != ""
  def2 <- def2[keep, , drop = FALSE]

  # Corresponding error:
  #   "Definition sheet must contain at least one non-empty parameter row."
  if (nrow(def2) == 0) {
    return(fail("Definition sheet must contain at least one non-empty parameter row."))
  }

  # Check duplicate Parameter names.
  # Corresponding error:
  #   "Definition sheet contains duplicated Parameter name(s): ..."
  if (anyDuplicated(def2$Parameter)) {
    dup <- unique(def2$Parameter[duplicated(def2$Parameter)])
    return(fail(sprintf("Definition sheet contains duplicated Parameter name(s): %s", paste(dup, collapse = ", "))))
  }

  # Check Type values.
  # Corresponding error:
  #   "Definition sheet has invalid Type value(s)..."
  # Accepted values are only: continuous / categorical
  valid_types <- c("continuous", "categorical")
  bad_type <- is.na(def2$Type) | !(def2$Type %in% valid_types)
  if (any(bad_type)) {
    bad_rows <- paste0(def2$Parameter[bad_type], " (row ", def2$row_no[bad_type], ")")
    return(fail(sprintf("Definition sheet has invalid Type value(s). Use only 'continuous' or 'categorical'. Problem rows: %s", paste(bad_rows, collapse = ", "))))
  }

  # Detect X and Y parameters from the Parameter names.
  X_names <- def2$Parameter[grepl("^X", def2$Parameter, ignore.case = TRUE)]
  Y_names <- def2$Parameter[grepl("^Y", def2$Parameter, ignore.case = TRUE)]

  # Corresponding error:
  #   "Definition must contain at least one X parameter..."
  if (length(X_names) < 1) return(fail("Definition must contain at least one X parameter (e.g., X1)."))

  # Corresponding error:
  #   "Definition must contain at least one Y parameter..."
  if (length(Y_names) < 1) return(fail("Definition must contain at least one Y parameter (e.g., Y1)."))

  # Check Data has the mandatory id column.
  # Corresponding error:
  #   "Data sheet must contain column 'id'."
  if (!("id" %in% names(dat))) return(fail("Data sheet must contain column 'id'."))

  # Check all X columns defined in Definition exist in Data.
  # Corresponding error:
  #   "Data sheet must contain all X columns defined in Definition. Missing: ..."
  if (!all(X_names %in% names(dat))) {
    miss <- setdiff(X_names, names(dat))
    return(fail(sprintf("Data sheet must contain all X columns defined in Definition. Missing: %s", paste(miss, collapse = ", "))))
  }

  # Check all Y columns defined in Definition exist in Data.
  # Corresponding error:
  #   "Data sheet must contain all Y columns defined in Definition. Missing: ..."
  if (!all(Y_names %in% names(dat))) {
    miss <- setdiff(Y_names, names(dat))
    return(fail(sprintf("Data sheet must contain all Y columns defined in Definition. Missing: %s", paste(miss, collapse = ", "))))
  }

  # Corresponding error:
  #   "Data sheet must contain at least one data row."
  if (nrow(dat) < 1) {
    return(fail("Data sheet must contain at least one data row."))
  }

  # Validate id values in Data.
  id_chr <- as.character(dat$id)

  # Corresponding error:
  #   "Data sheet column 'id' contains blank value(s)..."
  if (any(is.na(id_chr) | trimws(id_chr) == "")) {
    bad_rows <- which(is.na(id_chr) | trimws(id_chr) == "") + 1L
    return(fail(sprintf("Data sheet column 'id' contains blank value(s). Problem row(s): %s", paste(bad_rows, collapse = ", "))))
  }

  # Corresponding error:
  #   "Data sheet column 'id' contains duplicated value(s): ..."
  if (anyDuplicated(id_chr)) {
    dup <- unique(id_chr[duplicated(id_chr)])
    return(fail(sprintf("Data sheet column 'id' contains duplicated value(s): %s", paste(dup, collapse = ", "))))
  }

  # Split X into continuous and categorical based on validated Type.
  X_cont <- def2$Parameter[def2$Type == "continuous"  & def2$Parameter %in% X_names]
  X_cat  <- def2$Parameter[def2$Type == "categorical" & def2$Parameter %in% X_names]

  # Corresponding error:
  #   "Definition must contain at least one continuous X parameter..."
  # This is required because the current GP workflow expects at least one
  # continuous input.
  if (length(X_cont) < 1) {
    return(fail("Definition must contain at least one continuous X parameter (Type = 'continuous')."))
  }

  # Validate continuous X definitions one by one.
  for (nm in X_cont) {
    rr <- def2[def2$Parameter == nm, , drop = FALSE]
    mn <- suppressWarnings(as.numeric(rr$Min_raw[1]))
    st <- suppressWarnings(as.numeric(rr$Standard_raw[1]))
    mx <- suppressWarnings(as.numeric(rr$Max_raw[1]))
    it_raw <- rr$Interval_raw[1]
    it <- suppressWarnings(as.numeric(it_raw))

    # Corresponding error:
    #   "Definition for continuous parameter 'Xn' must have numeric Min, Standard, and Max."
    if (!is.finite(mn) || !is.finite(st) || !is.finite(mx)) {
      return(fail(sprintf("Definition for continuous parameter '%s' must have numeric Min, Standard, and Max.", nm)))
    }

    # Corresponding error:
    #   "Definition for continuous parameter 'Xn' must satisfy Min < Max."
    if (!(mn < mx)) {
      return(fail(sprintf("Definition for continuous parameter '%s' must satisfy Min < Max.", nm)))
    }

    # Corresponding error:
    #   "Definition for continuous parameter 'Xn' must satisfy Min <= Standard <= Max."
    if (st < mn || st > mx) {
      return(fail(sprintf("Definition for continuous parameter '%s' must satisfy Min <= Standard <= Max.", nm)))
    }

    # Corresponding error:
    #   "Definition for continuous parameter 'Xn' must have a positive numeric Interval or blank."
    # Allowed cases:
    #   - blank Interval
    #   - numeric Interval > 0
    if (!(is.na(it_raw) || trimws(it_raw) == "" || (is.finite(it) && it > 0))) {
      return(fail(sprintf("Definition for continuous parameter '%s' must have a positive numeric Interval or blank.", nm)))
    }
  }

  # Validate categorical X definitions.
  # Rule: each categorical parameter must have at least one known level,
  # either in Definition (Min/Standard/Max) or in Data.
  for (nm in X_cat) {
    rr <- def2[def2$Parameter == nm, , drop = FALSE]
    lv <- c(rr$Min_raw[1], rr$Standard_raw[1], rr$Max_raw[1])
    lv <- lv[!is.na(lv) & trimws(lv) != ""]
    dat_lv <- unique(as.character(dat[[nm]]))
    dat_lv <- dat_lv[!is.na(dat_lv) & trimws(dat_lv) != ""]

    # Corresponding error:
    #   "Definition/Data for categorical parameter 'Xn' must contain at least one level."
    if (length(lv) == 0 && length(dat_lv) == 0) {
      return(fail(sprintf("Definition/Data for categorical parameter '%s' must contain at least one level.", nm)))
    }
  }

  # Validate each Y has a non-empty Purpose.
  for (nm in Y_names) {
    rr <- def2[def2$Parameter == nm, , drop = FALSE]
    purp <- rr$Purpose[1]

    # Corresponding error:
    #   "Definition for output 'Yn' must have a non-empty Purpose."
    if (is.na(purp) || trimws(purp) == "") {
      return(fail(sprintf("Definition for output '%s' must have a non-empty Purpose.", nm)))
    }
  }

  # Detect whether an extra Data column name is an allowed derived-variable formula.
  # Allowed derived forms are intentionally aligned with server.R logic.
  #
  # Corresponding error category:
  #   Unexpected columns in Data that are NOT one of the supported derived forms
  #   based on Definition-defined continuous X variables.
  #
  # Examples accepted when X1, X2 are defined as continuous in Definition:
  #   X1
  #   X1*X1
  #   X1*X2
  #   1/X1
  #   exp(X1)
  #   exp(-X1)
  #   log(X1)
  detect_formula_from_name <- function(col_name, x_vars) {
    if (length(x_vars) == 0) return(FALSE)
    nm <- trimws(as.character(col_name))
    xp <- paste0("(", paste(x_vars, collapse = "|"), ")")
    patterns <- c(
      paste0("^", xp, "$"),
      paste0("^", xp, "\\s*\\*\\s*", xp, "$"),
      paste0("^1\\s*/\\s*", xp, "$"),
      paste0("^exp\\(", xp, "\\)$"),
      paste0("^exp\\(-", xp, "\\)$"),
      paste0("^log\\(", xp, "\\)$"),
      paste0("^log10\\(", xp, "\\)$"),
      paste0("^sqrt\\(", xp, "\\)$"),
      paste0("^sin\\(", xp, "\\)$"),
      paste0("^cos\\(", xp, "\\)$")
    )
    any(vapply(patterns, function(p) grepl(p, nm), logical(1)))
  }

  # Check extra Data columns that are not explicitly defined in Definition.
  # Rule:
  #   - Columns listed in Definition (id / X / Y) are always allowed.
  #   - Extra columns are allowed only when their column names are supported
  #     derived-variable formulas built from Definition-defined continuous X.
  #   - Any other extra column is treated as an input mistake and rejected.
  #
  # Corresponding error:
  #   "Data sheet contains column(s) not defined in Definition and not recognized
  #    as supported derived-variable names: ..."
  base_cols <- c("id", X_names, Y_names)
  extra_cols <- setdiff(names(dat), base_cols)
  if (length(extra_cols) > 0) {
    bad_extra <- extra_cols[!vapply(extra_cols, detect_formula_from_name, logical(1), x_vars = X_cont)]
    if (length(bad_extra) > 0) {
      return(fail(sprintf(
        paste0(
          "Data sheet contains column(s) not defined in Definition and not recognized as supported derived-variable names: %s. ",
          "Allowed derived examples based on Definition-defined continuous X are forms such as X1*X2, 1/X1, exp(X1), exp(-X1), log(X1)."
        ),
        paste(bad_extra, collapse = ", ")
      )))
    }
  }

  # Helper for numeric Data column validation.
  # Corresponding errors:
  #   - blank numeric cell(s)
  #   - non-numeric numeric cell(s)
  check_numeric_column <- function(vec, nm, sheet_name = "Data") {
    chr <- as.character(vec)
    blank <- is.na(chr) | trimws(chr) == ""

    # Corresponding error:
    #   "Data sheet column '...' contains blank value(s)..."
    if (any(blank)) {
      bad_rows <- which(blank) + 1L
      return(sprintf("%s sheet column '%s' contains blank value(s). Problem row(s): %s", sheet_name, nm, paste(bad_rows, collapse = ", ")))
    }

    num <- suppressWarnings(as.numeric(vec))
    bad <- !is.finite(num)

    # Corresponding error:
    #   "Data sheet column '...' must contain numeric values only..."
    if (any(bad)) {
      bad_rows <- which(bad) + 1L
      return(sprintf("%s sheet column '%s' must contain numeric values only. Problem row(s): %s", sheet_name, nm, paste(bad_rows, collapse = ", ")))
    }

    NULL
  }

  # Validate all continuous X and all Y columns in Data as numeric columns.
  for (nm in c(X_cont, Y_names)) {
    msg <- check_numeric_column(dat[[nm]], nm, "Data")
    if (!is.null(msg)) return(fail(msg))
  }

  # Validate categorical Data columns are not blank.
  for (nm in X_cat) {
    chr <- as.character(dat[[nm]])
    bad <- is.na(chr) | trimws(chr) == ""

    # Corresponding error:
    #   "Data sheet column 'Xn' contains blank value(s)..."
    if (any(bad)) {
      bad_rows <- which(bad) + 1L
      return(fail(sprintf("Data sheet column '%s' contains blank value(s). Problem row(s): %s", nm, paste(bad_rows, collapse = ", "))))
    }
  }

  # Validation passed.
  # server.R can safely reuse the workbook metadata and raw sheets.
  list(
    error = NULL,
    sheets = sheets,
    normalized_sheets = ns,
    i_def = i_def,
    i_data = i_data,
    def_raw = def_raw,
    data_raw = data_raw
  )
}
