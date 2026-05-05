# ============================================================
# Semi-parametric Bayesian regression: y = X beta + u + eps
# beta ~ N(mu0, Sigma0), u ~ N(0, K), eps ~ N(0, sigma2 I)
# Hyperparameters (kernel + sigma2) are treated as fixed.
# ============================================================

# ---------- Fit function ---------- #Step1 posterior beta|y
fit_semiparam_bayes <- function(y, X, Z, Z_cat=NULL, sigma_cat2=10,
                                mu0 = NULL,#beta事前
                                Sigma0 = 100,#beta事前
                                sigma2 = 1.0,#ε分散
                                ell = 1.0,#rbf距離parameter
                                sf2 = 1.0,#rbf係数parameter
                                jitter = 1e-8) {
  
  y <- as.numeric(y)
  X <- as.matrix(X)
  Z <- as.matrix(Z)
  n <- length(y)
  p <- ncol(X)
  
  if (is.null(mu0)) mu0 <- rep(0, p)
  if (is.null(Sigma0)) Sigma0 <- diag(1e4, p)  # weak prior by default (assumes standardized X)
  mu0 <- as.numeric(mu0)
  Sigma0 <- as.matrix(Sigma0)
  
  #categorical factor
  K_cat <- NULL
  sigmas2_cat <- NULL
  
  if (!is.null(Z_cat)) {
    if (nrow(Z_cat) != n) stop("nrow(Z_cat) must equal length(y).")
    
    K_cat_raw <- additive_delta_kernels(Z_cat, sigma2 = sigma_cat2)
    
    # additive_delta_kernels() returns a list -> use Kc_total
    if (is.list(K_cat_raw) && !is.null(K_cat_raw$Kc_total)) {
      K_cat <- K_cat_raw$Kc_total
      sigmas2_cat <- K_cat_raw$sigmas2
    } else if (is.matrix(K_cat_raw)) {
      K_cat <- K_cat_raw
      sigmas2_cat <- NULL
    } else {
      stop("additive_delta_kernels() returned unsupported type: ", paste(class(K_cat_raw), collapse = ", "))
    }
    
    K_cat <- as.matrix(K_cat)
    storage.mode(K_cat) <- "double"
    if (!all(dim(K_cat) == c(n, n))) stop("K_cat must be n x n.")
  }
  
  
  # Kernel + noise
  K <- kernel_matrix(Z, Z, type="rbf", theta2 = ell, theta1 = sf2)
  V <- K + sigma2 * diag(n)
  # Categorical kernel
  if (!is.null(K_cat)) V <- V + K_cat
  
  # Add jitter for numerical stability
  V <- V + jitter * diag(n)
  
  # Cholesky: V = L L^T
  L <- chol(V)  # upper-tri by default in R: chol(V) returns U s.t. t(U)U = V
  # We'll convert to lower-tri for forwardsolve/backsolve style:
  # If U is upper, then V = t(U)U => let L = t(U)
  L <- t(L)
  
  # Precompute: V^{-1} X and V^{-1} y
  VinvX <- chol_solve(L, X)         # n x p
  Vinvy <- chol_solve(L, y)         # n
  
  # Posterior for beta: Sigma_beta^{-1} = Sigma0^{-1} + X^T V^{-1} X
  Sigma0_inv <- solve(Sigma0)       # p x p (small p; OK)
  Sigma_beta_inv <- Sigma0_inv + t(X) %*% VinvX
  Sigma_beta <- solve(Sigma_beta_inv)#Q^-1
  
  mu_beta <- Sigma_beta %*% (Sigma0_inv %*% mu0 + t(X) %*% Vinvy)
  mu_beta <- as.numeric(mu_beta)
  
  # Linear residual: y - X mu_beta (= u + eps)
  r_lin <- y - as.numeric(X %*% mu_beta)
  Vinv_r <- chol_solve(L, r_lin)          # V^{-1} r
  u_hat  <- as.numeric(K %*% Vinv_r)      # E[u|y] at training points (continuous part)
  # If categorical kernel was used, add its contribution to u_hat as well
  if (!is.null(K_cat)) {
    u_hat <- u_hat + as.numeric(K_cat %*% Vinv_r)
  }
  y_hat <- as.numeric(X %*% mu_beta + u_hat)
  # Noise-like residual: eps_hat = y - X mu_beta - u_hat = y - y_hat
  eps_hat <- y - y_hat #residual
  eps_var_hat <- if (n > 1) var(eps_hat) else NA_real_ #residual var
  rmse_total <- sqrt(mean((eps_hat)^2)) #rmse
  R2 <- cor(y, y_hat, use = "complete.obs")^2
  
  # Store objects needed for prediction
  list(
    y = y, X = X, Z = Z,
    Z_cat  = if (!is.null(Z_cat)) as.data.frame(Z_cat) else NULL,
    mu0 = mu0, Sigma0 = Sigma0,
    sigma2 = sigma2, ell = ell, sf2 = sf2,
    sigma_cat2 = sigma_cat2,
    K = K, V = V, L = L,  # L is lower-tri s.t. V = L L^T
    VinvX = VinvX, Vinvy = Vinvy,
    mu_beta = mu_beta, Sigma_beta = Sigma_beta,
    sigma_cat2s = sigmas2_cat,
    y_hat = y_hat,
    u_hat = u_hat,              # posterior mean of u at training points
    eps_hat = eps_hat,        # y - X mu_beta - u_hat
    eps_var_hat = eps_var_hat,
    rmse_total = rmse_total,
    R2 = R2
  )
}

# ---------- Predict function (mean/var + variance decomposition) ---------- #Step2 Posterior u|beta, y
predict_semiparam_bayes <- function(fit, Xnew, Znew, Z_cat_new  = NULL,
                                    return_components = TRUE) {
  Xnew <- as.matrix(Xnew)
  Znew <- as.matrix(Znew)
  
  y <- fit$y; X <- fit$X; Z <- fit$Z
  mu_beta <- fit$mu_beta
  Sigma_beta <- fit$Sigma_beta
  sigma2 <- fit$sigma2
  L <- fit$L
  n <- length(y)
  m <- nrow(Xnew)
  
  # K_* (n x m), k_** (m)
  Kstar <- kernel_matrix(Z, Znew, theta1 = fit$sf2, theta2 = fit$ell)     # n x m
  kss <- diag(kernel_matrix(Znew, Znew,  theta1 = fit$sf2, theta2 = fit$ell))  # m
  
  
  # ---------- categorical変数に対して (ここから) --------------------------------------
  Kstar_c <- NULL
  kss_c <- rep(0, m)
  if (!is.null(fit$Z_cat)) {
    if (is.null(Z_cat_new)) stop("fit used Z_cat, but Z_cat_new is NULL.")
    Z_cat_new <- as.data.frame(Z_cat_new)
    
    cols <- names(fit$Z_cat)
    missing <- setdiff(cols, names(Z_cat_new))
    if (length(missing) > 0) stop("Z_cat_new missing columns: ", paste(missing, collapse = ", "))
    
    sig2 <- fit$sigma_cat2s
    if (is.null(sig2)) {
      # fallback: scalar provided
      sig2 <- setNames(rep(as.numeric(fit$sigma_cat2), length(cols)), cols)
    } else {
      sig2 <- sig2[cols]
    }
    
    Kstar_list <- lapply(cols, function(col) {
      delta_kernel(fit$Z_cat[[col]], Z_cat_new[[col]], sigma2 = sig2[[col]])
    })
    Kstar_c <- Reduce(`+`, Kstar_list)
    kss_c <- rep(sum(sig2), m)  # delta(c,c)=1 for each col
  }
  
  if (!is.null(Kstar_c)) {
    Kstar <- Kstar + Kstar_c
    kss <- kss + kss_c
  }
  # ---------- categorical変数に対して (ここまで) --------------------------------------
  
  
  # a = V^{-1} k_*  (n x m)
  a <- chol_solve(L, Kstar)   # n x m
  
  # Mean:
  # E[y*|y] = x*^T mu_beta + k_*^T V^{-1} (y - X mu_beta)
  r <- y - as.numeric(X %*% mu_beta)         # n
  Vinvr <- chol_solve(L, r)                  # n
  mean_gp <- colSums(Kstar * Vinvr)          # m (since k_*^T Vinvr)
  mean_lin <- as.numeric(Xnew %*% mu_beta)   # m
  mean <- mean_lin + mean_gp                 # m
  
  # Variance components:
  # v_gp = k** - k_*^T V^{-1} k_*
  # compute diag(Kstar^T a) efficiently: sum over rows of Kstar * a
  diag_kVinvk <- colSums(Kstar * a)          # m
  v_gp <- pmax(kss - diag_kVinvk, 0)         # numeric guard
  
  # delta = x_* - X^T V^{-1} k_*
  Xt_a <- t(X) %*% a                          # p x m
  delta <- t(Xnew) - Xt_a                     # p x m  (each column is delta for a point)
  
  # v_beta = delta^T Sigma_beta delta  for each m
  # compute per column: t(delta[,i]) %*% Sigma_beta %*% delta[,i]
  Sb_delta <- Sigma_beta %*% delta            # p x m
  v_beta <- colSums(delta * Sb_delta)         # m
  
  # total predictive variance (for observed y*): sigma2 + v_gp + v_beta
  v_total <- sigma2 + v_gp + v_beta
  
  if (!return_components) {
    return(list(mean = mean, var = v_total))
  }
  
  # dominance ratio (ignoring sigma2): beta vs gp
  denom <- v_gp + v_beta
  r_beta <- ifelse(denom > 0, v_beta / denom, NA_real_)
  
  list(
    mean = mean,
    var_total = v_total,
    var_noise = rep(sigma2, m),
    var_gp = v_gp,
    var_beta = v_beta,
    r_beta = r_beta
  )
}

# ============================================================
# Example usage (replace with your data)
# ============================================================


# Suppose:
# y: n-vector
# X: n x p design matrix (include intercept column if you want)
# Z: n x d GP inputs (can be same as X columns if you want, but see note below)

# ---- Whether applying box-cox transformation
# lambda <- 0.3           # ON
 lambda <- NULL          # OFF


###############################################################################
# --- Toy example -----------------------------------------------------------
###############################################################################
if (FALSE) {
  set.seed(1)
  n <- 5
  x1 <- seq(-1, 1, length=n)
  x2 <- c("A","B","A","B","A")
  X <- cbind(1, x1)# Only continuous
  Z <- cbind(x1)        # GP on same 2 dims
  
  #categorical
  Z_cat <- data.frame("Xc" = as.character(x2))
  Z_cat
  y_true <- function(x, sd){
    y_true <- 1 + 3*x - 0.5*exp(-2*(x-1)) + 3*rnorm(n, sd = sd)
    #return (abs(y_true)/max(y_true))
    return (y_true/max(y_true))
  }
  set.seed(1)
  y_org <- y_true(x1, sd=2) #+ x2: categorical
  x1
  y_org
  plot(x1, y_org, xlab = "x", ylab = "y")
  
  y <- fwd_y(y_org, lambda=lambda) #lambdaがNULLでなければbox-cox変換をする
  
  #standardize
  std <- standardize_fit(X, Z, y, standardize_X = TRUE, intercept_col = 1L)
  X_s <- std$X; Z_s <- std$Z; y_s <- std$y
  
  ################################################################################
  # Hyperparameters (fixed)
  ################################################################################
  sigma2 <- 0.05 #εの分散: NULLなら線形回帰の残差から推定, 値を指定してもよい.
  var_beta0 <- 100 #大きな値(e.g.100)→GP支配. 小さな値(ex, 0.1)→線形支配.
  if (is.null(sigma2)){
    fit_lm <- lm(y_s ~ X_s - 1)
    sigma2_lin <- sum(resid(fit_lm)^2) / df.residual(fit_lm)  # unbiased
    sigma2 <- sigma2_lin/10 
  } else{
    sigma2 <- sigma2
  }
  # Prior on beta
  p <- ncol(X) #線形のparameter数
  mu0 <- rep(0, p) #βの事前分布平均
  Sigma0 <- diag(var_beta0, p) #大きな値→GP支配. 小さな値→線形支配.
  
  ell <- 0.4 #rbf kernelの距離paramemter
  sf2 <- 1.0 #rbf kernelの係数
  
  # ------------------ hyperparameterを推定する場合 -----------------------------
  # hyp <- fit_hyperparams_multistart_bounded(
  #   y = y_s, X = X_s, Z = Z_s,
  #   mu0 = mu0, Sigma0 = Sigma0,
  #   ell_grid = c(0.5, 2, 5),
  #   sf2_grid = c(0.1, 1, 10),
  #   sigma2_grid = c(1,5,10),
  #   ell_bounds = c(0.1, 20),
  #   sf2_bounds = c(1e-2, 1e2),
  #   sigma2_bounds = c(1, 10)
  # )
  # hyp$ell; hyp$sf2; hyp$sigma2
  # hyp$opt$value  # minimized negative log marginal likelihood
  #------------------------------------------------------------------------------
  
  
  fit <- fit_semiparam_bayes(y_s, X_s, Z_s, Z_cat = Z_cat,
                             mu0 = mu0, Sigma0 = Sigma0,
                             sigma2 = sigma2, ell = ell, sf2 = sf2)
  
  
  # ------------------- Predict on new points ------------------------------------
  m <- 100
  x1n <- seq(-2, 2, length.out = m)
  Xnew <- cbind(1, x1n) #, exp(-x1n)などの非線形を足してもよい
  Znew <- cbind(x1n)
  Z_cat_new <- data.frame(Xc = rep("A", m))  # 例えば全部Aに固定
  new_s <- standardize_apply(Xnew, Znew, std)
  pred_s <- predict_semiparam_bayes(fit, new_s$X, new_s$Z, Z_cat_new = Z_cat_new,
                                    return_components = TRUE)
  
  
  y_pred <- destandardize_y(pred_s$mean, std) #正規化逆変換
  sd_y<- destandardize_y_sd(sqrt(pred_s$var_total), std) #正規化逆変換
  y_org_pred <- inv_y(y_pred, lambda=lambda)# lambdaがNULLでなければbox-cox逆変換
  y_lo <- y_pred - sd_y
  y_hi <- y_pred + sd_y
  y_org_lo <- inv_y(y_lo, lambda)
  y_org_hi <- inv_y(y_hi, lambda)
  
  #semi-parameteric bayes
  plot(x1,y_org, xlab = "x", ylab = "y", pch=16,
       xlim=c(min(x1n), max(x1n)), ylim = c(min(y_org_lo), max(y_org_hi)))
  lines(x1n, y_org_pred, col="blue", lty=2)
  lines(x1n, y_org_lo, col="blue")
  lines(x1n, y_org_hi, col="blue")
  lines(x1n, y_true(x1n, 0), lwd=2)
  #lines(x1n, 20*pred$r_beta, col="green")
  #色塗
  polygon(
    c(x1n, rev(x1n)),
    c(y_org_lo, rev(y_org_hi)),
    col=rgb(0, 0, 1, alpha = 0.05),
    border = NA
  )
  
  #linear component
  beta_var <- fit$Sigma_beta
  beta_var
  beta_lo <- fit$mu_beta - diag(beta_var)
  beta_hi <- fit$mu_beta + diag(beta_var)
  # 2) 標準化空間で線形成分を計算
  Xnew_s <- new_s$X
  y_lin_s <- as.numeric(Xnew_s %*% fit$mu_beta)
  # 3) y を元スケールに戻す
  y_lin <- destandardize_y(y_lin_s, std)
  y_lo <- Xnew %*% beta_lo
  y_hi <- Xnew %*% beta_hi
  lines(x1n, y_lin, col="red", lty=2)
  #lines(x1n, y_lo, col="red")
  #lines(x1n, y_hi, col="red")
  
  #普通の最小二乗法
  #res <- lm(y~(x1+x2+1))
  #y_lm <- Xnew %*% res$coefficients
  # lines(x1n, y_lm)
  
  # ----------------------- 通常のGPと比較 -----------------------------------
  #kernel計算
  theta1 <- sf2
  theta2 <- ell^2
  sigma2
  theta3 <- sigma2#noise
  #予測分布の計算 p(y*|x*,X,y)
  res <- GP_pred(X_train=Z_s, Y_train=y_s, X_pred=new_s$Z, type = "rbf",
                 theta1 = theta1, theta2 = theta2, theta3 = theta3)
  mu <- destandardize_y(res$mu, std)
  var <- destandardize_y_sd(sqrt(diag(res$var_y)), std)
  
  
  #予測
  lines(x1n, mu, col="lightblue")
  y_min <- mu-sqrt(var)
  y_max <- mu+sqrt(var)
  lines(x1n, y_min, col="lightblue")#y_min
  lines(x1n, y_max, col="lightblue")#y_max
  #色塗
  polygon(
    c(x1n, rev(x1n)),
    c(y_min, rev(y_max)),
    col=rgb(0.68, 0.85, 0.90, alpha = 0.3),
    border = NA
  )
  legend("topleft",
         legend = c("Training data",
                    "Semi",
                    "GP"),
         pch    = c(16, NA, NA),
         lty    = c(NA, 1, 1),
         lwd    = c(NA, 5, 5),
         col    = c("black",
                    "blue",
                    "lightblue"),
         pt.cex = 1,
         cex = 0.8,
         bty    = "n")
}
