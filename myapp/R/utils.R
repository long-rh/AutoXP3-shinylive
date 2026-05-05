# -----------------------------
# Helpers: parsing & utilities
# -----------------------------

normalize_sheet_name <- function(x) tolower(gsub("\\s+", "", x))

get_cat_levels <- function(def_row) {
  lev <- c(def_row$Min_raw[1], def_row$Standard_raw[1], def_row$Max_raw[1])
  lev <- lev[!is.na(lev) & trimws(lev) != ""]
  unique(lev)
}

parse_purpose <- function(p) {
  p <- trimws(as.character(p))
  if (is.na(p) || p == "") return(list(type = "none", op = NA, value = NA_real_))
  
  # Excel由来の全角記号を半角に寄せる
  p <- chartr("＜＞＝", "<>=", p)
  
  # 空白除去
  p2 <- gsub("\\s+", "", p)
  
  # 不等号・等号（明示）
  if (grepl("^>=", p2)) return(list(type = "bound", op = ">=", value = suppressWarnings(as.numeric(sub("^>=", "", p2)))))
  if (grepl("^<=", p2)) return(list(type = "bound", op = "<=", value = suppressWarnings(as.numeric(sub("^<=", "", p2)))))
  if (grepl("^>",  p2)) return(list(type = "bound", op = ">",  value = suppressWarnings(as.numeric(sub("^>",  "", p2)))))
  if (grepl("^<",  p2)) return(list(type = "bound", op = "<",  value = suppressWarnings(as.numeric(sub("^<",  "", p2)))))
  
  # "=" が付いたターゲット
  if (grepl("^=", p2)) {
    v <- suppressWarnings(as.numeric(sub("^=", "", p2)))
    return(list(type = "target", op = "=", value = v))
  }
  
  # 数値だけ（暗黙の "="）
  if (grepl("^[+-]?[0-9.]+([eE][+-]?[0-9]+)?$", p2)) {
    return(list(type = "target", op = "=", value = as.numeric(p2)))
  }
  
  list(type = "unknown", op = NA, value = NA_real_)
}

# ---- prediction wrapper (raw X -> predict mean/var on original y scale) ----
predict_fun <- function(fit_wrap, Xraw_new) {
  if (!is.list(fit_wrap) || is.null(fit_wrap$fit) || is.null(fit_wrap$std)) {
    stop("Model is not fitted yet. Click 'Fit model' first.")
  }
  fit    <- fit_wrap$fit
  std    <- fit_wrap$std
  lambda <- fit_wrap$lambda
  
  Xraw_new <- as.matrix(Xraw_new)
  
  # build Xnew(with intercept) & Znew(raw)
  Xnew <- cbind(1, Xraw_new)
  Znew <- Xraw_new
  
  new_s <- standardize_apply(Xnew, Znew, std)
  
  pr_s <- predict_semiparam_bayes(
    fit,
    Xnew = new_s$X,
    Znew = new_s$Z,
    Z_cat_new = NULL,
    return_components = FALSE
  )
  
  mu_s <- as.numeric(pr_s$mean)
  v_s  <- as.numeric(pr_s$var)
  sd_s <- sqrt(pmax(v_s, 0))
  
  mu <- destandardize_y(mu_s, std)
  sd <- destandardize_y_sd(sd_s, std)
  
  if (!is.null(lambda) && exists("inv_y", mode = "function")) {
    mu <- inv_y(mu, lambda = lambda)
    # sd の厳密な逆変換は今は省略（lambda=NULL前提なら問題なし）
  }
  
  list(mean = mu, var = sd^2, mean_s = mu_s, sd_s = sd_s)
}


make_grid_1d <- function(x_min, x_max, interval, max_n = 20) {
  
  if (!is.finite(x_min) || !is.finite(x_max) || x_max <= x_min) {
    stop("Invalid range.")
  }
  
  # interval無効 → 20分割
  if (is.na(interval) || !is.finite(interval) || interval <= 0) {
    return(seq(x_min, x_max, length.out = max_n))
  }
  
  # intervalあり
  g <- seq(x_min, x_max, by = interval)
  
  # 点数が多すぎる場合は間引く
  if (length(g) > max_n) {
    idx <- unique(round(seq(1, length(g), length.out = max_n)))
    g <- g[idx]
  }
  
  return(g)
}
