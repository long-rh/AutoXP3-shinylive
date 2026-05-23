standardize_fit <- function(X, Z, y,
                            standardize_X = TRUE,
                            intercept_col = 1L) {
  X <- as.matrix(X)
  Z <- as.matrix(Z)
  y <- as.numeric(y)
  
  n <- length(y)
  p <- ncol(X)
  d <- ncol(Z)
  
  # --- y center/scale ---
  y_mean <- mean(y)
  y_sd   <- sd(y)
  if (y_sd == 0) y_sd <- 1
  y_s <- (y - y_mean) / y_sd
  
  # --- Z standardize ---
  Z_mean <- colMeans(Z)
  Z_sd <- apply(Z, 2, sd)
  Z_sd[Z_sd == 0] <- 1
  Z_s <- sweep(sweep(Z, 2, Z_mean, "-"), 2, Z_sd, "/")
  
  # --- X standardize (optional) ---
  X_s <- X
  X_mean <- rep(0, p)
  X_sd   <- rep(1, p)
  
  if (standardize_X) {
    for (j in seq_len(p)) {
      if (!is.null(intercept_col) && j == intercept_col) {
        # intercept column left unchanged
        X_mean[j] <- 0
        X_sd[j] <- 1
      } else {
        X_mean[j] <- mean(X[, j])
        X_sd[j]   <- sd(X[, j])
        if (X_sd[j] == 0) X_sd[j] <- 1
        X_s[, j] <- (X[, j] - X_mean[j]) / X_sd[j]
      }
    }
  }
  
  list(
    X = X_s, Z = Z_s, y = y_s,
    y_mean = y_mean, y_sd = y_sd,
    Z_mean = Z_mean, Z_sd = Z_sd,
    X_mean = X_mean, X_sd = X_sd,
    standardize_X = standardize_X,
    intercept_col = intercept_col
  )
}

standardize_apply <- function(Xnew, Znew, std) {
  Xnew <- as.matrix(Xnew)
  Znew <- as.matrix(Znew)
  
  # apply Z transform
  Z_s <- sweep(sweep(Znew, 2, std$Z_mean, "-"), 2, std$Z_sd, "/")
  
  # apply X transform (if used)
  X_s <- Xnew
  if (isTRUE(std$standardize_X)) {
    p <- ncol(Xnew)
    for (j in seq_len(p)) {
      if (!is.null(std$intercept_col) && j == std$intercept_col) {
        # intercept unchanged
      } else {
        X_s[, j] <- (Xnew[, j] - std$X_mean[j]) / std$X_sd[j]
      }
    }
  }
  
  list(X = X_s, Z = Z_s)
}

prior_to_standardized_scale <- function(mu0_orig, sig0_orig, std, all_cont) {
  p <- length(mu0_orig)
  
  mu0_std  <- as.numeric(mu0_orig)
  sig0_std <- as.numeric(sig0_orig)
  
  names(mu0_std)  <- c("(intercept)", all_cont)[seq_len(p)]
  names(sig0_std) <- c("(intercept)", all_cont)[seq_len(p)]
  
  # slopes
  if (p >= 2) {
    for (j in 2:p) {
      mu0_std[j]  <- mu0_orig[j] * std$X_sd[j] / std$y_sd
      sig0_std[j] <- sig0_orig[j] * (std$X_sd[j] / std$y_sd)^2
    }
  }
  
  # intercept mean
  intercept_std <- (mu0_orig[1] - std$y_mean) / std$y_sd
  if (p >= 2) {
    intercept_std <- intercept_std + sum((mu0_orig[2:p] * std$X_mean[2:p]) / std$y_sd)
  }
  mu0_std[1] <- intercept_std
  
  # diagonal approximation for intercept variance
  sig0_std[1] <- sig0_orig[1] / (std$y_sd^2)
  
  list(mu0 = mu0_std, sig0 = sig0_std)
}


# For prediction mean back-transform:
# if y was standardized: y = y_mean + y_sd * y_scaled
destandardize_y <- function(y_scaled, std) {
  std$y_mean + std$y_sd * y_scaled
}

destandardize_y_sd <- function(sd_scaled, std) {
  std$y_sd * sd_scaled
}

beta_to_original_scale <- function(mu_beta_std, std, all_cont) {
  p <- length(mu_beta_std)
  
  beta_orig <- as.numeric(mu_beta_std)
  names(beta_orig) <- c("(intercept)", all_cont)[seq_len(p)]
  
  # slopes
  if (p >= 2) {
    for (j in 2:p) {
      beta_orig[j] <- mu_beta_std[j] * std$y_sd / std$X_sd[j]
    }
  }
  
  # intercept
  intercept_orig <- std$y_mean + std$y_sd * mu_beta_std[1]
  if (p >= 2) {
    intercept_orig <- intercept_orig - sum(beta_orig[2:p] * std$X_mean[2:p])
  }
  beta_orig[1] <- intercept_orig
  
  beta_orig
}


# --------------- Yeo-Johnson ----------------------------
# 任意の実数 y に対応（負値でも適用可）
# lambda = 1 のとき恒等変換
yeojohnson_transform <- function(y, lambda) {
  result <- numeric(length(y))
  pos <- y >= 0

  if (any(pos)) {
    yp <- y[pos]
    if (abs(lambda) < 1e-8) {
      result[pos] <- log1p(yp)
    } else {
      result[pos] <- ((yp + 1)^lambda - 1) / lambda
    }
  }

  if (any(!pos)) {
    yn <- y[!pos]
    if (abs(lambda - 2) < 1e-8) {
      result[!pos] <- -log1p(-yn)
    } else {
      result[!pos] <- -((-yn + 1)^(2 - lambda) - 1) / (2 - lambda)
    }
  }
  result
}

yeojohnson_inverse <- function(z, lambda) {
  result <- numeric(length(z))
  pos <- z >= 0

  if (any(pos)) {
    zp <- z[pos]
    if (abs(lambda) < 1e-8) {
      result[pos] <- expm1(zp)
    } else {
      result[pos] <- (lambda * zp + 1)^(1 / lambda) - 1
    }
  }

  if (any(!pos)) {
    zn <- z[!pos]
    if (abs(lambda - 2) < 1e-8) {
      result[!pos] <- -expm1(-zn)
    } else {
      result[!pos] <- 1 - (1 - (2 - lambda) * zn)^(1 / (2 - lambda))
    }
  }
  result
}

use_transform <- function(lambda) is.numeric(lambda) && length(lambda) == 1L && is.finite(lambda)

# 変換 ON/OFF（lambda = NULL で恒等変換）
fwd_y <- function(y, lambda = NULL) {
  if (use_transform(lambda)) yeojohnson_transform(y, lambda) else y
}

inv_y <- function(z, lambda = NULL) {
  if (use_transform(lambda)) yeojohnson_inverse(z, lambda) else z
}
