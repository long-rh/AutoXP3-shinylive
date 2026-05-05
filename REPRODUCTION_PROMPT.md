# AutoXP3 Reproduction Prompt: Optimization from an Excel File and Save-Result-Format Excel Output

This prompt describes **only the R functions used and their inputs/outputs** so that another AI (or human) can reproduce the same procedure. It does not include implementation code (formulas or concrete vector operations). The assumption is that the AI receives **exactly one Excel file**. The final deliverable is a `.xlsx` in the same format as the output of the **"Save Result" button** in the Shiny app AutoXP3.

---

## Overview (minimal pseudocode)

```text
# Input : input.xlsx  (Definition and Data sheets required)
# Output: <original-name>_<YYYYMMDDHHMM>.xlsx  (all original sheets + Fit info + Optimize)

# 1) Read
defs, data, all_sheets  = read_excel(input.xlsx)
X_cont, X_cat, Y_names  = parse Definition
purposes                = parse_purpose(Purpose column of Y rows)   # §1

# 2) Fit semi-parametric Bayesian regression for each Y
for yn in Y_names:
    std       = standardize_fit(X=cbind(1,X_cont_train), Z=X_cont_train, y=data[yn])
    prior_std = prior_to_standardized_scale(mu0=0, sig0=100, std)  # convert original-scale prior to standardized scale
    fit       = fit_semiparam_bayes(std$y, std$X, std$Z, Z_cat,
                                    mu0=prior_std$mu0, Sigma0=diag(prior_std$sig0),
                                    sigma2=0.05, ell=0.4, sf2=1.0, sigma_cat2=0.5)
    beta      = beta_to_original_scale(fit$mu_beta, std)            # β for display
    y_pred    = predict_semiparam_bayes(fit, training X) → original scale  # for R²/RMSE recomputation

# 3) Build candidate set (exact app reproduction: LHS 100 pts + corners ≤ 2048 pts)
set.seed(1)
cand_list = 1D candidates per variable (continuous: seq(..., by=h) or length.out=21; categorical: all levels)
grid_df   = if prod(|cand_list|) ≤ 100:  expand.grid(cand_list)
            else:                         LHS(n=100) continuous + categorical
grid_df   = unique(rbind(grid_df, (min,max) corners for all variables))  # only when total corners ≤ 2048

# 4) Predict (μ, σ) for each Y over the candidate set
for yn:  all_mu[yn], all_sd[yn] = predict_semiparam_bayes(...) → original scale
         (use var_total = σ² + v_gp + v_beta for variance)

# 5) UCB → Desirability → scope extraction
for kappa in (0, 2):                        # Optimize=0, Explore=2
    D_single[yn, kappa] = minmax(ucb_score(μ, σ, Purpose, kappa))
    D_all[kappa]        = geomean(D_single[:, kappa])
scopes =  top-2 per Y (Optimize) + top-3 All (Optimize)
        + top-2 per Y (Explore)

# 6) Combine candidate table, deduplicate, number
combined = rbind(scopes) → unique by (Scope, X values)
                         → order by Mode, TargetY, Rank
                         → Candidate = cand1..N
                         → round(numerics, 4)

# 7) Write Save-Result-format Excel
sheets = [all original sheets] + [Fit info: build_fit_info_lines() for each Y] + [Optimize: combined]
write_xlsx(sheets, "<base>_<YYYYMMDDHHMM>.xlsx")
```

See §0–§13 below for details. Numerical reference example for verification: §12 (Sample8).

---

## 0. Prerequisites

- **Input**: One Excel file `input.xlsx` provided by the user
  - Required sheets: `Definition`, `Data`
  - Optional sheets: `Note`, `Candidate`, etc. (preserved as-is if present)
- **R source files**: `myapp/R/`
  - `utils.R` — parsing, grid generation
  - `standardize.R` — standardization / de-standardization / prior scale conversion
  - `semiparam_bayes.R` — semi-parametric Bayesian regression fit/predict
  - `kernel.R` — RBF kernel
  - `categorical-kernel.R` — delta kernel for categorical variables
  - `optimize_ucb.R` — UCB acquisition function (`ucb_score`)
  - `server.R` — scope generation and Save Result output on the Shiny server side (`compute_D`, `compute_single_y_desirability`, `make_scope_df`, `build_fit_info_lines`, `download_model`)
- **Default hyperparameters (same as the app)**
  - `ell = 0.4` (RBF lengthscale = `theta2`)
  - `sf2 = 1.0` (RBF signal variance = `theta1`)
  - `sigma2 = 0.05` (observation noise variance)
  - `sigma_cat2 = 0.5` (categorical kernel variance)
  - Prior: **in original scale**, `β ~ N(0, 100·I)`
  - `kappa`: Optimize = 0, Explore = 2
- **Random seed**: **Call `set.seed(1)` immediately before** the LHS for candidate generation (same as the app)

---

## 1. Reading the Input Excel

**Input**: path to `input.xlsx`  
**Output**: continuous variable names `X_cont`, categorical variable names `X_cat`, output variable names `Y_names`, Min/Max/Interval/Purpose for each variable, training data `(X_train, Y_train)`.

Sheet specification:
- `Definition`: columns `Parameter / Type(continuous|categorical) / Min_raw / Standard_raw / Max_raw / Interval / Purpose`
- `Data`: training data (each row = one sample; columns = X and Y)

**Important — Purpose applies to Y rows only**: Purpose is read only from Y rows. Purpose on X rows is ignored. If a Y row's Purpose is `NA` or empty, treat it as `type="none"` (pure exploration).

Parsing the `Purpose` string:
> **`utils.R :: parse_purpose(p)`**
> - Input: string (e.g. `">0"`, `"<=5"`, `"=10"`, `"7"`; full-width ＜＞＝ also accepted)
> - Output: `list(type, op, value)` where `type ∈ {bound, target, none, unknown}`

1D candidate list for continuous variables (**exactly matches app's server.R:1202–1208**):
- If `Interval` is finite and `> 0` → `seq(min, max, by = Interval)`
- Otherwise → `seq(min, max, length.out = 21)` (**21 points**)
- If length < 2 → `c(min, max)`

Categorical level extraction:
> **`utils.R :: get_cat_levels(def_row)`**
> - Input: one row of Definition
> - Output: deduplicated level vector (order taken from `Min_raw, Standard_raw, Max_raw`)

---

## 2. Standardization and Prior Scale Conversion

**Purpose**: To obtain the same numerical results as the app, specify the linear-coefficient prior as `β ~ N(0, 100·I)` **in original scale** and convert it to standardized scale before estimation.

> **`standardize.R :: standardize_fit(X, Z, y, standardize_X=TRUE, intercept_col=1L)`**
> - Input: design matrix `X = cbind(1, X_cont_train)`, raw continuous variable matrix `Z = X_cont_train`, response `y`
> - Output: `list(X, Z, y, y_mean, y_sd, Z_mean, Z_sd, X_mean, X_sd, ...)`

> **`standardize.R :: prior_to_standardized_scale(mu0_orig, sig0_orig, std, all_cont)`**
> - Input: `mu0_orig = rep(0, p)`, `sig0_orig = rep(100, p)`, the `std` object above, `all_cont = X_cont`
> - Output: `list(mu0, sig0)` (standardized scale; pass to `fit_semiparam_bayes` as `mu0=prior$mu0, Sigma0=diag(prior$sig0)`)

> **`standardize.R :: standardize_apply(Xnew, Znew, std)`**
> - Transforms new `(Xnew, Znew)` to the same scaling as training, for use at prediction time

> **`standardize.R :: beta_to_original_scale(mu_beta_std, std, all_cont)`**
> - Recovers fitted `β` to original scale. **Always use this output for the `Fit info` sheet and the linear equation display in Save Result.**

> **`standardize.R :: destandardize_y(mu_s, std)` / `destandardize_y_sd(sd_s, std)`**
> - Transforms predicted mean / SD back to original scale

---

## 3. Fitting the Semi-parametric Bayesian Regression (per Y)

> **`semiparam_bayes.R :: fit_semiparam_bayes(y, X, Z, Z_cat, mu0, Sigma0, sigma2, ell, sf2, sigma_cat2, jitter=1e-8)`**
> - Model: `y = Xβ + u + ε`,  `β ~ N(mu0, Sigma0)`,  `u ~ GP(0, K_RBF + K_cat)`,  `ε ~ N(0, σ²·I)`
> - Kernels: `kernel.R :: rbf_kernel(Z1, Z2, ell, sf2)` and `categorical-kernel.R :: additive_delta_kernels(Z_cat, sigma2=sigma_cat2)` (delta kernels summed across columns)
> - Input: standardized `y, X, Z`. If no categorical variables, pass `Z_cat = NULL`; otherwise pass a `data.frame` with column names = `X_cat`, each column as `as.character`
> - Output: `fit` object (`mu_beta, Sigma_beta, L, V, K, y_hat, u_hat, eps_hat, eps_var_hat, rmse_total, R2, ...`)

Retain a `fit_wrap` object for each Y. Minimum required fields:
```
fit_wrap = list(
  fit          = <fit object>,
  std          = <standardize_fit output>,
  lambda       = NULL,                        # Yeo-Johnson disabled by default
  y_name       = <Y name>,
  all_cont     = X_cont,
  mu_beta_orig = beta_to_original_scale(fit$mu_beta, std, X_cont),
  yorg         = <original-scale y_train>,
  y_pred       = <original-scale prediction on training X, see §6>
)
```

---

## 4. Generating the Candidate Set (exact app reproduction, server.R 1194–1248)

**Policy**: Do not use a full `expand.grid`. The app caps candidates at roughly **≤ 2,148 points** using LHS + corner points.

### 4.1 Per-variable 1D candidates (`cand_list`)
Build for each `X_i` using the rules in §1 (continuous: `seq(..., by=h)` or `seq(..., length.out=21)`; categorical: `get_cat_levels()`).

### 4.2 Total product check
`n_all = prod(sapply(cand_list, length))`

### 4.3 Main sampling
- **`n_all <= 100`**: `grid_df = expand.grid(cand_list, KEEP.OUT.ATTRS=FALSE, stringsAsFactors=FALSE)`
- **`n_all > 100`**:
  1. Call `set.seed(1)`
  2. Initialize `grid_df` as an empty data frame with `N_SAMPLE = 100` rows
  3. For each categorical column: assign `sample(cand_list[[nm]], size=100, replace=TRUE)`
  4. For continuous variables, apply Latin Hypercube Sampling:
     - `lhs_unit(n, d)`: for each column `j`, `perm = sample.int(n, n, replace=FALSE)`, `U[,j] = (perm - runif(n)) / n`
     - Map `U[,j]` to discrete values in `cand_list[[nm]]`: `vv[pmin(m, pmax(1, floor(U[,j]*m) + 1L))]` where `m = length(vv)`

### 4.4 Adding corner points
- `ext_list = lapply(Xnames, function(nm) { vv <- cand_list[[nm]]; c(vv[1], vv[length(vv)]) })`  
  (continuous: `(min, max)`; categorical: first and last levels)
- `n_corners = prod(sapply(ext_list, length))`
- **Only if `n_corners <= MAX_CORNERS = 2048`**:  
  `grid_df = unique(rbind(grid_df, expand.grid(ext_list, KEEP.OUT.ATTRS=FALSE, stringsAsFactors=FALSE)))`
- Skip corner addition if the total exceeds `2048`

### 4.5 Derived variables and constraints
- `derived_cols` (if user-specified): `grid_df[[col]] <- eval(parse(text=formula_str), envir=grid_df)`
- `constraints` (list of constraint expressions): evaluate each with `eval(parse(text=expr), envir=as.list(grid_df))`, AND the results into `keep`, then `grid_df <- grid_df[keep, ]`

### 4.6 Splitting for prediction
- `Xnew_cont = as.matrix(grid_df[, X_cont_all])` (type double); `X_cont_all = c(X_cont, derived_cols)`
- `Z_cat_new = data.frame(grid_df[, X_cat])` → each column `as.character()`. `NULL` if no categoricals.
- `Xnew = cbind(1, Xnew_cont)`, `Znew = Xnew_cont`

---

## 5. Prediction over Candidates

For each Y:
```
ns = standardize_apply(Xnew, Znew, std)
pr = predict_semiparam_bayes(fit, Xnew=ns$X, Znew=ns$Z,
                             Z_cat_new = Z_cat_new,
                             return_components = TRUE)
all_mu[[yn]] = destandardize_y   (pr$mean,                    std)
all_sd[[yn]] = destandardize_y_sd(sqrt(pmax(pr$var_total, 0)), std)
```

**Note**: Use `var_total = sigma2 + v_gp + v_beta` (includes observation noise variance). Using only `v_gp` will give smaller SD and diverge from the app.

---

## 6. Training-set Prediction (for `Fit info` R²/RMSE)

`build_fit_info_lines` recomputes `eps var`, `RMSE`, and `R²` from **original-scale residuals** `yorg - y_pred`. Do **not** use `fit$R2` or `fit$rmse_total` directly.

```
pr_tr  = predict_semiparam_bayes(fit, Xnew=fit$X, Znew=fit$Z,
                                  Z_cat_new=fit$Z_cat, return_components=FALSE)
y_pred = destandardize_y(pr_tr$mean, std)   # original scale
# lambda=NULL assumed, so inv_y is the identity
```

Then:
```
resid_o      = yorg - y_pred
eps_var_orig = var(resid_o)                       # R's var(): (n-1) denominator
rmse_orig    = sqrt(mean(resid_o^2))
ss_res       = sum(resid_o^2)
R2_orig      = 1 - ss_res / sum((yorg - mean(yorg))^2)
```

---

## 7. UCB and Desirability (matches server.R 1314–1349 exactly)

### 7.1 Branching logic of `optimize_ucb.R :: ucb_score(mu, sd, purpose, kappa)`
- Purpose = `"="` or target (`type="target"`) → `score = -|mu - target| + kappa·sd`
- Purpose other than bound (`none`, `unknown`, etc.) → `score = mu + kappa·sd`
- Purpose = `">"`, `">="` → `score = (mu - thr) + kappa·sd`
- Purpose = `"<"`, `"<="` → `score = (thr - mu) + kappa·sd`
- `sd` is clipped by `pmax(sd, 1e-12)`

### 7.2 Per-Y desirability (recomputed for **each** `kappa`)
```
score_y = ucb_score(all_mu[[yn]], all_sd[[yn]], purp_y, kappa)
lo = min(score_y);  hi = max(score_y)
if (hi > lo)   D_single[yn] = clip((score_y - lo) / (hi - lo), 0, 1)
else           D_single[yn] = rep(0.5, length(score_y))
```

### 7.3 Combined desirability across all Y
```
D_mat = cbind(D_single[Y1], D_single[Y2], ...)   # per-Y desirabilities
D_all = apply(D_mat, 1, function(row) prod(pmax(row, 1e-6))^(1 / ncol(D_mat)))
```
(geometric mean; each element floor-clipped at 1e-6)

**Important**: Recompute scores, `D_single`, and `D_all` from scratch for each of `kappa=0` and `kappa=2`.

---

## 8. Scope Extraction and Candidate Table Assembly (server.R 1357–1445)

### 8.1 Building `base_df`
```
base_df = grid_df[, Xnames]
for yn in Y_names:
    base_df[[paste0("Pred.", yn)]] = all_mu[[yn]]
    base_df[[paste0("SD.",   yn)]] = all_sd[[yn]]
```
Column names follow **`paste0("Pred.", Y-name)` / `paste0("SD.", Y-name)`** exactly (Y name used verbatim).

### 8.2 `make_scope_df(scope_label, desirability, n_top, mode_key, target_y_key)`
```
tmp = base_df
tmp$Desirability  = desirability
tmp$.mode_key     = mode_key
tmp$.target_key   = target_y_key
tmp$Scope         = scope_label
tmp = tmp[order(tmp$Desirability, decreasing = TRUE), ]   # R's default order()
tmp = head(tmp, n_top)
tmp$RankInScope = 1..nrow(tmp)
return tmp
```

### 8.3 Scope extraction order
```
result_list = list()
# Per-Y Optimize: 2 candidates each
for yn in Y_names:
    result_list[["opt_" + yn]] = make_scope_df("Optimize " + yn, D_single[yn](kappa=0), 2, "Optimize", yn)
# Optimize All: 3 candidates
result_list[["opt_all"]]       = make_scope_df("Optimize All",   D_all(kappa=0),         3, "Optimize", "All")
# Per-Y Explore: 2 candidates each
for yn in Y_names:
    result_list[["exp_" + yn]] = make_scope_df("Explore " + yn,  D_single[yn](kappa=2),  2, "Explore",  yn)
combined = do.call(rbind, result_list)
```

### 8.4 Deduplication, ordering, and numbering
```
# Rows sharing (Scope, X values) across scopes are duplicates
key = paste(combined$Scope, combined[, Xnames], sep = "\r")
combined = combined[!duplicated(key), ]

# Sort: Optimize Y... → Optimize All → Explore Y... → then by RankInScope
combined$.mode_key   = factor(combined$.mode_key,   levels = c("Optimize", "Explore"))
combined$.target_key = factor(combined$.target_key, levels = c(Y_names, "All"))
combined = combined[order(combined$.mode_key, combined$.target_key, combined$RankInScope), ]

# Drop internal sort keys
combined$.mode_key   = NULL
combined$.target_key = NULL

# Final Candidate labels (sequential, in row order)
combined = cbind(Candidate = sprintf("cand%d", seq_len(nrow(combined))), combined)

# Rename columns
names(combined)[names(combined) == "RankInScope"]  = "Rank"
names(combined)[names(combined) == "Desirability"] = "Score"

# Round numeric columns (except "Rank") to 4 decimal places
for col in numeric cols except "Rank":
    combined[[col]] = round(combined[[col]], 4)
combined[["Rank"]] = as.integer(...)
```

**Final column order**:
`Candidate, Scope, Rank, Score, <Xnames...>, Pred.Y1, SD.Y1, ..., Pred.Yk, SD.Yk`

---

## 9. Writing the Save-Result-Format Excel (matches server.R 807–861 exactly)

**Filename**: `<original-filename-without-extension>_<YYYYMMDDHHMM>.xlsx` (local time)

**Sheet order**:
1. **All sheets from the original Excel, transferred as-is.** Read sheet names via `readxl::excel_sheets()`, read each as a `data.frame` with `readxl::read_excel()`, and write back with `writexl::write_xlsx()`. **Formatting, formulas, merged cells, and date formats are not preserved** (types are inferred by `read_excel`).
2. **`Fit info` sheet (new)**: columns = `Output, Line`. Stack the output of `build_fit_info_lines(fit_wrap)` for each Y vertically. Only the first cell of the `Output` column contains the Y name; the rest are empty strings. Append one blank row at the end of each Y block.
3. **`Optimize` sheet**: write `combined` (the candidate table from §8). **Omit this sheet** if the candidate table is empty.

### 9.1 Verbatim output specification for `build_fit_info_lines(fit_wrap)`

The `sprintf` formats below must be reproduced **exactly** (use Unicode characters such as middle dot `·`, σ², Greek ε directly):

```
Semi-parametric Bayesian regression
<Yname> = <β0:%.4f>·1 + <β1:%.4f>·X1 + ... + <βp:%.4f>·<Xp-name> + u + ε
beta ~ N(mu0, Sigma0),  u ~ GP(0, K),  ε ~ N(0, σ² I)

[Posterior beta | y] (original scale)
  mu_beta[1]  ((intercept))        = <+%.6f>
  mu_beta[2]  (X1)                 = <+%.6f>
  ...
  mu_beta[p+1] (<Xp-name>)         = <+%.6f>

[Hyperparameters]
theta1 (RBF scale)       = <%.4f>
theta2 (lengthscale)     = <%.4f>
sigma2 (noise var)       = <%.6f>
sigma_cat (cat. var.)    = <%.6f>

[Residuals] (original scale)
eps var.= <%.4f>,  RMSE = <%.4f>,  R2 = <%.4f>
```

Formatting details (exact `sprintf` spec):
- Linear equation terms: concatenate `"%.4f·<Xname>"` with `" + "`; the intercept term alone is `"%.4f·1"`
- `mu_beta` block: `sprintf("  mu_beta[%d]  %-20s = %+.6f", i, paste0("(", x_labels[i], ")"), beta[i])`
  - `%-20s`: left-justified in 20 characters. Label is `"((intercept))"` for the intercept only; `"(Xname)"` for all others
  - `%+.6f`: sign-forced 6-decimal float (positive values show `+`, negative show `-`)
- `theta1`/`theta2`: `%.4f`; `sigma2`/`sigma_cat`: `%.6f`
- Residuals row: `%.4f`

---

## 10. Randomness, Rounding, and Numerical Precision

- Call `set.seed(1)` **exactly once**, immediately before the LHS in §4.3 (nowhere else)
- Numeric columns in `combined` are ultimately rounded to 4 decimal places via `round(x, 4)` (except `Rank`)
- Numeric display in `Fit info` follows the `sprintf` format in §9.1
- Cholesky jitter: `jitter = 1e-8` (default in `fit_semiparam_bayes`)

---

## 11. Complete Flow (pseudocode)

```text
upload_path = "input.xlsx"

# §1: Parse
all_sheets = excel_sheets(upload_path)
sheets_list = lapply(all_sheets, read_excel, path = upload_path)
defs        = Definition sheet
data        = Data sheet
X_cont, X_cat, Y_names, purposes = parse defs (Purpose from Y rows only)
cand_list   = per-variable 1D lists (§4.1)

# §2–§3: Fit each Y
for yn in Y_names:
    y_train_o = data[[yn]]
    std       = standardize_fit(cbind(1,X_cont_train), X_cont_train, y_train_o)
    prior_std = prior_to_standardized_scale(rep(0,p), rep(100,p), std, X_cont)
    fit       = fit_semiparam_bayes(std$y, std$X, std$Z, Z_cat,
                                    mu0=prior_std$mu0,
                                    Sigma0=diag(prior_std$sig0),
                                    sigma2=0.05, ell=0.4, sf2=1.0,
                                    sigma_cat2=0.5, jitter=1e-8)
    beta_orig = beta_to_original_scale(fit$mu_beta, std, X_cont)
    # §6: training-set prediction (for Fit info R²/RMSE)
    pr_tr     = predict_semiparam_bayes(fit, fit$X, fit$Z, fit$Z_cat, FALSE)
    y_pred_o  = destandardize_y(pr_tr$mean, std)
    fits[[yn]] = fit_wrap(fit, std, lambda=NULL, y_name=yn, all_cont=X_cont,
                          mu_beta_orig=beta_orig, yorg=y_train_o, y_pred=y_pred_o)

# §4: Candidate generation (exact app reproduction)
set.seed(1)
grid_df   = lhs_plus_corners(cand_list, N_SAMPLE=100, MAX_CORNERS=2048)
apply derived_cols / constraints (§4.5)
Xnew, Znew, Z_cat_new = split (§4.6)

# §5: Predict
for yn in Y_names:
    ns = standardize_apply(Xnew, Znew, fits[[yn]]$std)
    pr = predict_semiparam_bayes(fits[[yn]]$fit, ns$X, ns$Z, Z_cat_new, return_components=TRUE)
    all_mu[yn] = destandardize_y   (pr$mean,                    fits[[yn]]$std)
    all_sd[yn] = destandardize_y_sd(sqrt(pmax(pr$var_total, 0)),fits[[yn]]$std)

# §7–§8: UCB / Desirability / Scopes
for kappa in (0, 2):
    for yn in Y_names: D_single[yn, kappa] = ...
    D_all[kappa] = geom_mean(D_single[., kappa])
combined = assemble(Optimize κ=0 top-2 per Y + top-3 All,
                    Explore  κ=2 top-2 per Y,
                    dedupe by (Scope, X values),
                    order by mode_key / target_key / RankInScope,
                    renumber cand1..N,
                    round 4 dp)

# §9: Save Result Excel
sheets_list[["Fit info"]] = stack(build_fit_info_lines(fits[[yn]]) for yn in Y_names)
if nrow(combined) > 0: sheets_list[["Optimize"]] = combined
write_xlsx(sheets_list, path = sprintf("%s_%s.xlsx",
                                       tools::file_path_sans_ext(basename(upload_path)),
                                       format(Sys.time(), "%Y%m%d%H%M")))
```

---

## 12. Reference Output (Sample8 for numerical verification)

### 12.1 Input
`Sample8.xlsx` — `X1..X5` continuous (integer steps 0..10, so `length.out` fallback gives 11 points each), Y1, Purpose = `">0"`, n_train = 20.

### 12.2 Expected `Fit info` sheet content (Y1 block)
```
Semi-parametric Bayesian regression
Y1 = 21.5594·1 + -2.8970·X1 + -3.6297·X2 + 0.0000·X3 + 0.0000·X4 + 0.0000·X5 + u + ε
beta ~ N(mu0, Sigma0),  u ~ GP(0, K),  ε ~ N(0, σ² I)

[Posterior beta | y] (original scale)
  mu_beta[1]  ((intercept))        = +21.559403
  mu_beta[2]  (X1)                 = -2.896958
  mu_beta[3]  (X2)                 = -3.629749
  mu_beta[4]  (X3)                 = +0.000000
  mu_beta[5]  (X4)                 = +0.000000
  mu_beta[6]  (X5)                 = +0.000000

[Hyperparameters]
theta1 (RBF scale)       = 1.0000
theta2 (lengthscale)     = 0.4000
sigma2 (noise var)       = 0.050000
sigma_cat (cat. var.)    = 0.500000

[Residuals] (original scale)
eps var.= 0.0549,  RMSE = 0.2283,  R2 = 0.9998
```

### 12.3 Expected characteristics of the `Optimize` sheet (partial)
- `combined` should have **roughly 12–16 rows** (sampled from LHS 100 pts + 32 corner pts = 132 pts via §4)
- All rows may show `Score = 1.0000` (because the linear term saturates at `X1=X2=0`)
- Column order: `Candidate, Scope, Rank, Score, X1, X2, X3, X4, X5, Pred.Y1, SD.Y1`
- Scope order: `Optimize Y1 → Optimize All → Explore Y1`; within each scope, ascending `Rank`
- `Candidate` is a sequential label `cand1, cand2, ...` (corresponding to the above ordering)

**Verification checkpoints**:
- `Fit info` values for `(intercept), X1, X2` **exactly match** `+21.559403, -2.896958, -3.629749` → prior scale conversion in §2 is correct
- Candidate count in `Optimize` sheet is **≤ 132** → LHS + corners in §4 is correct (not the 74,519-row full grid)

---

## 13. Pitfalls

- **Using `100·I` directly in standardized scale gives different numbers.** Always pass through `prior_to_standardized_scale()`.
- **Keep candidates to ≤ 2,148 points** using LHS + corners. Do not build a full grid with `expand.grid` — it explodes with large `d` and changes results.
- Call `set.seed(1)` exactly once, immediately before §4.3. Do not use any random calls inside the fit loop, to avoid disrupting the random state.
- Skip corner addition when `MAX_CORNERS = 2048` is exceeded (occurs when `d_cont ≥ 12` continuous variables).
- If no categorical variables, pass `Z_cat = NULL` / `Z_cat_new = NULL` to both fit and predict. If present, pass a `data.frame` with each column as `as.character`.
- **Use `var_total = sigma2 + v_gp + v_beta`** for prediction variance. Using only `v_gp` will not match the app.
- `Fit info` values for `R²/RMSE/eps var` must be recomputed from `yorg - y_pred` in original scale (not `fit$R2`).
- Candidate table column names follow **`paste0("Pred.", Y)` / `paste0("SD.", Y)`** exactly, even if Y names contain special characters.
- The output Excel preserves all original sheets in their original order, with `Fit info` then `Optimize` appended at the end.
- The filename timestamp follows `format(Sys.time(), "%Y%m%d%H%M")` (local time, minute precision).
