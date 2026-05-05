# ---- Additive delta kernels for any number of categorical columns ----
# df: data.frame whose columns are categorical (factor/character)
# Returns:
#  - Kc_total: sum of delta kernels across all categorical columns
#  - Kc_list : per-column delta kernel matrices
#  - sigmas2 : the sigma^2 used per column (named)
#
# Delta kernel for one categorical vector:
#   K[i,j] = sigma2 if cat_i == cat_j else 0

delta_kernel <- function(cat1, cat2, sigma2 = 0.05) {
  c1 <- as.character(as.factor(cat1))
  c2 <- as.character(as.factor(cat2))
  sigma2 * (outer(c1, c2, FUN = "==") * 1.0)
}

additive_delta_kernels <- function(df, sigma2 = 0.05, sigma2_by_col = NULL) {
  if (!is.data.frame(df)) stop("df must be a data.frame")
  
  n <- nrow(df)
  if (n == 0) stop("df has 0 rows")
  
  p <- ncol(df)
  if (p == 0) stop("df has 0 columns (no categorical variables).")
  
  # identify categorical columns automatically
  is_cat <- vapply(df, function(x) is.factor(x) || is.character(x), logical(1))
  if (!any(is_cat)) stop("No categorical columns found (factor/character).")
  
  cat_cols <- names(df)[is_cat]
  
  # set sigma^2 per column
  if (is.null(sigma2_by_col)) {
    sigmas2 <- setNames(rep(sigma2, length(cat_cols)), cat_cols)
  } else {
    if (is.null(names(sigma2_by_col))) stop("sigma2_by_col must be a named numeric vector.")
    missing <- setdiff(cat_cols, names(sigma2_by_col))
    if (length(missing) > 0) stop("sigma2_by_col is missing: ", paste(missing, collapse = ", "))
    sigmas2 <- sigma2_by_col[cat_cols]
  }
  
  # build per-column delta kernels and sum them
  Kc_list <- lapply(cat_cols, function(col) {
    delta_kernel(df[[col]], df[[col]], sigma2 = sigmas2[[col]])
  })
  names(Kc_list) <- cat_cols
  
  Kc_total <- Reduce(`+`, Kc_list)
  # numeric safety
  Kc_total <- (Kc_total + t(Kc_total)) / 2
  
  list(
    n = n,
    n_cat_vars = length(cat_cols),
    cat_vars = cat_cols,
    sigmas2 = sigmas2,
    Kc_list = Kc_list,
    Kc_total = Kc_total
  )
}

# ---- Example (your df) ----
# df <- data.frame(
#   C1 = factor(c("A", "B")),
#   C2 = factor(c("a", "b"))
# )
# 
# res <- additive_delta_kernels(df, sigma2 = c(0.05, 0.03))#categoryごとにσを指定可能
# 
# res$n_cat_vars      # number of categorical variables detected
# res$cat_vars        # their names
# res$Kc_list$C1       # delta kernel for C1
# res$Kc_list$C2       # delta kernel for C2
# res$Kc_total         # additive delta kernel sum: Kc1 + Kc2

