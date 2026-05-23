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
derived_cols, formulas  = parse Derived sheet (if present)   # §1
purposes                = parse_purpose(Purpose column of Y rows)   # §1

# 2) Fit semi-parametric Bayesian regression for each Y
#    (with optional auto 2nd-order term selection — see §3a)
for yn in Y_names:
    # Step A: 1st-order fit (base X_cont + derived_cols only)
    std       = standardize_fit(X=cbind(1, all_cont_train), Z=all_cont_train, y=data[yn])
    prior_std = prior_to_standardized_scale(mu0=0, sig0=100, std)
    fit       = fit_semiparam_bayes(std$y, std$X, std$Z, Z_cat, ...)
    beta      = beta_to_original_scale(fit$mu_beta, std, all_cont)
    y_pred    = predict_semiparam_bayes(fit, training X) → original scale

    # Step B (optional, "Auto 2nd-order terms" checkbox):
    #   select up to 3 quadratic/interaction terms from 1st-order residuals → §3a
    #   refit with those extra columns appended to all_cont

# 3) Build candidate set (exact app reproduction: LHS 100 pts + corners ≤ 2048 pts)
set.seed(1)
cand_list = 1D candidates per base variable (continuous: seq by h or length.out=21; categorical: all levels)
grid_df   = if prod(|cand_list|) ≤ 100:  expand.grid(cand_list)
            else:                         LHS(n=100) continuous + categorical
grid_df   = unique(rbind(grid_df, (min,max) corners for all variables))  # only when total corners ≤ 2048
# Add derived_cols and auto_quad columns to grid_df (§4.5)

# 4) Predict (μ, σ) for each Y over the candidate set
#    Each Y uses its own all_cont (may differ if auto 2nd-order terms differ per Y)
for yn:  all_mu[yn], all_sd[yn] = predict_semiparam_bayes(...) → original scale
         (use var_total = σ² + v_gp + v_beta for variance)

# 5) UCB → Desirability → scope extraction
for kappa in (0, 2):
    D_single[yn, kappa] = minmax(ucb_score(μ, σ, Purpose, kappa))
    D_all[kappa]        = geomean(D_single[:, kappa])   # only used when |Y_names| > 1

# Single Y:  top-5 Optimize Y1  + top-2 Explore Y1   (no "Optimize All")
# Multi  Y:  top-2 per Y (Optimize) + top-3 All (Optimize) + top-2 per Y (Explore)

# 6) Combine candidate table, deduplicate, number
combined = rbind(scopes) → unique by (Scope, X values)
                         → order by Mode, TargetY, Rank
                         → Candidate = cand1..N
                         → round(numerics, 4)

# 7) Write Save-Result-format Excel
#    Data sheet is augmented with auto_quad columns (if any) — see §9
sheets = [all original sheets (Data augmented)] + [Fit info] + [Optimize: combined]
write_xlsx(sheets, "<base>_<YYYYMMDDHHMM>.xlsx")
```

See §0–§13 below for details. Numerical reference example for verification: §12 (Sample8).

---

## 0. Prerequisites

- **Input**: One Excel file `input.xlsx` provided by the user
  - Required sheets: `Definition`, `Data`
  - Optional sheets: `Note`, `Derived`, `Candidate`, etc. (preserved as-is if present)
- **R source files**: `myapp/R/`
  - `utils.R` — parsing, grid generation
  - `standardize.R` — standardization / de-standardization / prior scale conversion
  - `semiparam_bayes.R` — semi-parametric Bayesian regression fit/predict
  - `kernel.R` — RBF kernel
  - `categorical-kernel.R` — delta kernel for categorical variables
  - `optimize_ucb.R` — UCB acquisition function (`ucb_score`)
  - `server.R` — scope generation and Save Result output on the Shiny server side (`select_quadratic_candidates`, `do_fit_one_with_quad`, `compute_D`, `compute_single_y_desirability`, `make_scope_df`, `build_fit_info_lines`, `download_model`)
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
**Output**: continuous variable names `X_cont`, categorical variable names `X_cat`, output variable names `Y_names`, Min/Max/Interval/Purpose for each variable, training data `(X_train, Y_train)`, derived column names and formulas.

Sheet specification:
- `Definition`: columns `Parameter / Type(continuous|categorical) / Min_raw / Standard_raw / Max_raw / Interval / Purpose`
- `Data`: training data (each row = one sample; columns = X and Y)
- `Derived` (optional): columns `Name / Formula`. Defines user-specified derived variables (e.g. `X1*X2`) evaluated from base X columns. Formula strings are stored as `derived_formulas[[name]]`.

**Important — Purpose applies to Y rows only**: Purpose is read only from Y rows. Purpose on X rows is ignored. If a Y row's Purpose is `NA` or empty, treat it as `type="none"` (pure exploration).

Parsing the `Purpose` string:
> **`utils.R :: parse_purpose(p)`**
> - Input: string (e.g. `">0"`, `"<=5"`, `"=10"`, `"7"`; full-width ＜＞＝ also accepted)
> - Output: `list(type, op, value)` where `type ∈ {bound, target, none, unknown}`

1D candidate list for continuous variables:
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
> - Input: design matrix `X = cbind(1, all_cont_train)`, raw continuous variable matrix `Z = all_cont_train`, response `y`
> - `all_cont_train` includes base `X_cont` + `derived_cols` + any auto-selected 2nd-order columns (for the refitted model)
> - Output: `list(X, Z, y, y_mean, y_sd, Z_mean, Z_sd, X_mean, X_sd, ...)`

> **`standardize.R :: prior_to_standardized_scale(mu0_orig, sig0_orig, std, all_cont)`**
> - Input: `mu0_orig = rep(0, p)`, `sig0_orig = rep(100, p)`, the `std` object above, `all_cont`
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

Retain a `fit_wrap` object for each Y. Required fields:
```
fit_wrap = list(
  fit               = <fit object>,
  std               = <standardize_fit output>,
  lambda            = NULL,                          # Yeo-Johnson disabled by default
  y_name            = <Y name>,
  X_cont            = X_cont,                        # base X only (for 2nd-order heredity)
  all_cont          = c(X_cont, derived_cols, auto_quad_names),  # all continuous predictors
  mu_beta_orig      = beta_to_original_scale(fit$mu_beta, std, all_cont),
  yorg              = <original-scale y_train>,
  y_pred            = <original-scale prediction on training X, see §6>,
  auto_quad_names   = character(0),                  # auto-selected 2nd-order term names (§3a)
  auto_quad_formulas = list()                        # named list: name → formula string (§3a)
)
```

---

## 3a. Auto 2nd-Order Term Selection (`select_quadratic_candidates`)

This optional step is triggered by the **"Auto 2nd-order terms"** checkbox in the app. When enabled, fitting for each Y becomes a two-stage procedure implemented in `do_fit_one_with_quad`:

**Stage 1**: Fit the 1st-order model (base `X_cont` + `derived_cols` only), producing `fw1`.

**Stage 2**: Call `select_quadratic_candidates(fw1, dat, X_cont_base)` to select additional terms, then refit with those terms appended.

### Algorithm of `select_quadratic_candidates`

Constants:
```
EFFECT_THRESHOLD = 0.20   # |β_rel| ≥ 20% of max|β| → variable is "important"
COR_THRESHOLD    = 0.30   # |cor with 1st-order residuals| ≥ 0.3 → term is selected
MAX_TERMS        = 3      # at most 3 auto terms added per Y
```

**Step 1 — Identify important base variables**:
```
beta_orig = fw1$mu_beta_orig          # original-scale β from 1st-order fit
# Extract β for base X_cont only (not derived_cols)
x_indices = match(X_cont_base, fw1$all_cont)
beta_x    = beta_orig[x_indices + 1L]   # +1L for intercept offset
eff       = abs(beta_x)
max_eff   = max(eff)
important = X_cont_base[ eff / max_eff >= EFFECT_THRESHOLD ]
```

**Step 2 — Generate candidate 2nd-order terms**:
```
candidates = {}   # name → column vector
formulas   = {}   # name → formula string

# Quadratic terms
for xn in important:
    nm = paste0(xn, "^2")
    if nm in derived_cols: skip          # avoid duplicating user-defined derived cols
    candidates[nm] = dat[[xn]]^2
    formulas[nm]   = paste0(xn, "^2")

# Interaction terms (strong heredity: both Xi and Xj must be in important)
for each pair (xi, xj) in combn(important, 2):
    nm = paste0(xi, "*", xj)
    if nm in derived_cols: skip          # avoid duplicating user-defined derived cols
    candidates[nm] = dat[[xi]] * dat[[xj]]
    formulas[nm]   = paste0(xi, " * ", xj)
```

**Step 3 — Filter by correlation with 1st-order residuals**:
```
resid1 = fw1$yorg - fw1$y_pred        # 1st-order residuals in original scale
for nm in candidates:
    ok     = is.finite(candidates[nm]) & is.finite(resid1)
    cors[nm] = if sum(ok) >= 3: abs(cor(candidates[nm][ok], resid1[ok]))
               else: 0

selected = names(cors)[ cors >= COR_THRESHOLD ]
selected = head( names(sort(cors[selected], decreasing=TRUE)), MAX_TERMS )
```

**Step 4 — Return**:
```
return list(
  df       = as.data.frame(candidates[selected], check.names = FALSE),  # ← must use check.names=FALSE
  formulas = formulas[selected]
)
```

> **Critical**: `check.names = FALSE` must be used when constructing the data frame. Without it, R mangles column names (e.g. `"X1*X3"` → `"X1.X3"`, `"X1^2"` → `"X1.2"`), which breaks formula lookup at prediction time.

**Stage 2 refit**: Call `fit_semiparam_bayes` again with `all_cont = c(X_cont, derived_cols, selected_names)` and the extra columns appended to the training design matrix. Store `auto_quad_names` and `auto_quad_formulas` in `fit_wrap`.

**If the checkbox is unchecked** (default), `auto_quad_names = character(0)` and `auto_quad_formulas = list()` — the model is the ordinary 1st-order fit.

---

## 4. Generating the Candidate Set (exact app reproduction)

**Policy**: Do not use a full `expand.grid`. The app caps candidates at roughly **≤ 2,148 points** using LHS + corner points.

### 4.1 Per-variable 1D candidates (`cand_list`)
Build for each **base** `X_i` (continuous and categorical) using the rules in §1. `derived_cols` and `auto_quad_names` are **not** in `cand_list` — they are computed from the base variables afterwards (§4.5).

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

### 4.5 Derived variables, auto 2nd-order terms, and constraints
```
# 1. User-defined derived columns
for col in derived_cols:
    grid_df[[col]] = eval(parse(text = derived_formulas[[col]]), envir = grid_df)

# 2. Constraints (filter rows)
for expr in constraints:
    keep = keep & eval(parse(text = expr), envir = as.list(grid_df))
grid_df = grid_df[keep, ]

# 3. Auto 2nd-order columns (one pass over all fitted Ys, skip already-added names)
already_added = {}
for yn in fitted_Ys:
    for nm in fits[[yn]]$auto_quad_names:
        if nm in already_added or nm in names(grid_df): mark added; next
        formula_str = fits[[yn]]$auto_quad_formulas[[nm]]
        grid_df[[nm]] = eval(parse(text = formula_str), envir = grid_df)
        mark nm as added
```

### 4.6 Splitting for prediction (per Y)
Each Y has its own `all_cont` (base X + derived + its own auto_quad terms):
```
for yn in fitted_Ys:
    y_all_cont = fits[[yn]]$all_cont
    # Ensure all required columns exist in grid_df (fill with NA if missing)
    Xcont_y = as.matrix(grid_df[, y_all_cont])   # type double
    Xnew_y  = cbind(1, Xcont_y)
    Znew_y  = Xcont_y
```

---

## 5. Prediction over Candidates

For each Y (using that Y's own `std`, `fit`, and `all_cont`):
```
ns = standardize_apply(Xnew_y, Znew_y, fits[[yn]]$std)
pr = predict_semiparam_bayes(fits[[yn]]$fit, Xnew=ns$X, Znew=ns$Z,
                             Z_cat_new = Z_cat_new,
                             return_components = TRUE)
all_mu[[yn]] = destandardize_y   (pr$mean,                    fits[[yn]]$std)
all_sd[[yn]] = destandardize_y_sd(sqrt(pmax(pr$var_total, 0)), fits[[yn]]$std)
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

## 7. UCB and Desirability (matches server.R exactly)

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

### 7.3 Combined desirability across all Y (multi-Y only)
```
D_mat = cbind(D_single[Y1], D_single[Y2], ...)   # per-Y desirabilities
D_all = apply(D_mat, 1, function(row) prod(pmax(row, 1e-6))^(1 / ncol(D_mat)))
```
(geometric mean; each element floor-clipped at 1e-6)

**Important**: Recompute scores, `D_single`, and `D_all` from scratch for each of `kappa=0` and `kappa=2`.

---

## 8. Scope Extraction and Candidate Table Assembly

### 8.1 Building `base_df`
```
base_df = grid_df[, Xnames]   # base X only (no derived/auto-quad cols in output table)
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
tmp = tmp[order(tmp$Desirability, decreasing = TRUE), ]
tmp = head(tmp, n_top)
tmp$RankInScope = 1..nrow(tmp)
return tmp
```

### 8.3 Scope extraction order

**Single Y** (`length(Y_names) == 1`):
```
result_list = list()
# Optimize Y1: 5 candidates (more than multi-Y, since no "Optimize All")
result_list[["opt_Y1"]] = make_scope_df("Optimize Y1", D_single[Y1](kappa=0), 5, "Optimize", Y1)
# No "Optimize All" — identical to "Optimize Y1" when there is only one output
# Explore Y1: 2 candidates
result_list[["exp_Y1"]] = make_scope_df("Explore Y1",  D_single[Y1](kappa=2), 2, "Explore",  Y1)
```

**Multiple Y** (`length(Y_names) > 1`):
```
result_list = list()
# Per-Y Optimize: 2 candidates each
for yn in Y_names:
    result_list[["opt_" + yn]] = make_scope_df("Optimize " + yn, D_single[yn](kappa=0), 2, "Optimize", yn)
# Optimize All: 3 candidates (geometric-mean desirability)
result_list[["opt_all"]]       = make_scope_df("Optimize All",   D_all(kappa=0),         3, "Optimize", "All")
# Per-Y Explore: 2 candidates each
for yn in Y_names:
    result_list[["exp_" + yn]] = make_scope_df("Explore " + yn,  D_single[yn](kappa=2),  2, "Explore",  yn)
```

### 8.4 Deduplication, ordering, and numbering
```
# Rows sharing (Scope, X values) within the combined table are duplicates
key = paste(combined$Scope, combined[, Xnames], sep = "\r")
combined = combined[!duplicated(key), ]

# Sort: Optimize Y... → (Optimize All if multi-Y) → Explore Y... → then by RankInScope
scope_levels = c(
  paste("Optimize", Y_names),
  if (multi_Y) "Optimize All",
  paste("Explore", Y_names)
)
combined$Scope = factor(combined$Scope, levels = scope_levels)
combined = combined[order(combined$.mode_key, combined$.target_key, combined$RankInScope), ]

# Drop internal sort keys, add Candidate labels
combined$.mode_key = combined$.target_key = NULL
combined = cbind(Candidate = sprintf("cand%d", seq_len(nrow(combined))), combined)

# Rename columns
names(combined)["RankInScope"] = "Rank"
names(combined)["Desirability"] = "Score"

# Round numeric columns (except "Rank") to 4 decimal places
for col in numeric cols except "Rank":
    combined[[col]] = round(combined[[col]], 4)
combined[["Rank"]] = as.integer(...)
```

**Final column order**:
`Candidate, Scope, Rank, Score, <Xnames...>, Pred.Y1, SD.Y1, ..., Pred.Yk, SD.Yk`

---

## 9. Writing the Save-Result-Format Excel

**Filename**: `<original-filename-without-extension>_<YYYYMMDDHHMM>.xlsx` (local time)

**Sheet order**:
1. **All sheets from the original Excel, transferred as-is** — except the `Data` sheet is augmented (see below).
2. **`Fit info` sheet (new)**: columns = `Output, Line`. Stack the output of `build_fit_info_lines(fit_wrap)` for each Y vertically. Only the first cell of the `Output` column contains the Y name; the rest are empty strings. Append one blank row at the end of each Y block.
3. **`Optimize` sheet**: write `combined` (the candidate table from §8). **Omit this sheet** if the candidate table is empty.

### 9.0 Augmenting the Data sheet with auto 2nd-order columns

If any Y has auto-selected 2nd-order terms, those columns are appended to the `Data` sheet **before writing**:
```
data_df = sheets_list[["Data"]]
all_auto_quad_info = {}   # collect unique name → formula across all fitted Ys
for yn in Y_names:
    for nm in fits[[yn]]$auto_quad_names:
        if nm not in all_auto_quad_info and nm not in names(data_df):
            all_auto_quad_info[nm] = fits[[yn]]$auto_quad_formulas[[nm]]

for nm in all_auto_quad_info:
    data_df[[nm]] = eval(parse(text = all_auto_quad_info[[nm]]), envir = as.list(data_df))

sheets_list[["Data"]] = data_df
```

### 9.1 Verbatim output specification for `build_fit_info_lines(fit_wrap)`

The `sprintf` formats below must be reproduced **exactly**:

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

[Auto-selected 2nd-order terms]       ← only present when auto_quad_names is non-empty
  <name1>: <formula1>
  <name2>: <formula2>
```

The linear equation and `[Posterior beta | y]` block include **all** terms in `all_cont` (base X + derived + auto_quad), in order. The `[Auto-selected 2nd-order terms]` section lists each auto-selected term name and its formula string (e.g. `X1^2: X1^2`, `X1*X3: X1 * X3`).

Formatting details (exact `sprintf` spec):
- Linear equation terms: concatenate `"%.4f·<Xname>"` with `" + "`; the intercept term alone is `"%.4f·1"`
- `mu_beta` block: `sprintf("  mu_beta[%d]  %-20s = %+.6f", i, paste0("(", x_labels[i], ")"), beta[i])`
  - `%-20s`: left-justified in 20 characters. Label is `"((intercept))"` for the intercept only; `"(Xname)"` for all others
  - `%+.6f`: sign-forced 6-decimal float
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
all_sheets   = excel_sheets(upload_path)
sheets_list  = lapply(all_sheets, read_excel, path = upload_path)
defs         = Definition sheet
data         = Data sheet
X_cont, X_cat, Y_names, purposes = parse defs (Purpose from Y rows only)
derived_cols, derived_formulas   = parse Derived sheet (if present)
cand_list    = per-variable 1D lists (§4.1, base X only)

# Compute derived columns in training data
for col in derived_cols:
    data[[col]] = eval(parse(text = derived_formulas[[col]]), envir = data)

# §2–§3: Fit each Y (with optional auto 2nd-order — §3a)
for yn in Y_names:
    y_train_o  = data[[yn]]

    # Stage 1: 1st-order fit
    all_cont_1 = c(X_cont, derived_cols)
    std1       = standardize_fit(cbind(1, all_cont_1 training), all_cont_1 training, y_train_o)
    prior_std1 = prior_to_standardized_scale(rep(0,p), rep(100,p), std1, all_cont_1)
    fit1       = fit_semiparam_bayes(std1$y, std1$X, std1$Z, Z_cat, mu0=..., ...)
    beta1      = beta_to_original_scale(fit1$mu_beta, std1, all_cont_1)
    pr_tr1     = predict_semiparam_bayes(fit1, fit1$X, fit1$Z, fit1$Z_cat, FALSE)
    y_pred1_o  = destandardize_y(pr_tr1$mean, std1)
    fw1 = fit_wrap(fit1, std1, ..., X_cont=X_cont, all_cont=all_cont_1,
                   mu_beta_orig=beta1, yorg=y_train_o, y_pred=y_pred1_o,
                   auto_quad_names=character(0), auto_quad_formulas=list())

    # Stage 2 (if "Auto 2nd-order terms" enabled):
    result = select_quadratic_candidates(fw1, data, X_cont)   # §3a
    if result$df is non-empty:
        extra_names  = names(result$df)
        extra_data   = result$df
        all_cont_2   = c(all_cont_1, extra_names)
        # Append extra columns to training matrix and refit
        std2       = standardize_fit(cbind(1, all_cont_2 training), all_cont_2 training, y_train_o)
        prior_std2 = prior_to_standardized_scale(rep(0,p2), rep(100,p2), std2, all_cont_2)
        fit2       = fit_semiparam_bayes(std2$y, std2$X, std2$Z, Z_cat, mu0=..., ...)
        beta2      = beta_to_original_scale(fit2$mu_beta, std2, all_cont_2)
        pr_tr2     = predict_semiparam_bayes(fit2, fit2$X, fit2$Z, fit2$Z_cat, FALSE)
        y_pred2_o  = destandardize_y(pr_tr2$mean, std2)
        fits[[yn]] = fit_wrap(fit2, std2, ..., X_cont=X_cont, all_cont=all_cont_2,
                              mu_beta_orig=beta2, yorg=y_train_o, y_pred=y_pred2_o,
                              auto_quad_names=extra_names,
                              auto_quad_formulas=result$formulas)
    else:
        fits[[yn]] = fw1

# §4: Candidate generation (exact app reproduction)
set.seed(1)
grid_df = lhs_plus_corners(cand_list, N_SAMPLE=100, MAX_CORNERS=2048)
apply derived_cols / constraints / auto_quad cols (§4.5)

# §5: Predict (per-Y all_cont)
for yn in Y_names:
    Xcont_y = as.matrix(grid_df[, fits[[yn]]$all_cont])
    ns = standardize_apply(cbind(1, Xcont_y), Xcont_y, fits[[yn]]$std)
    pr = predict_semiparam_bayes(fits[[yn]]$fit, ns$X, ns$Z, Z_cat_new, return_components=TRUE)
    all_mu[yn] = destandardize_y   (pr$mean,                    fits[[yn]]$std)
    all_sd[yn] = destandardize_y_sd(sqrt(pmax(pr$var_total, 0)), fits[[yn]]$std)

# §7–§8: UCB / Desirability / Scopes
for kappa in (0, 2):
    for yn in Y_names: D_single[yn, kappa] = ...
    if multi-Y: D_all[kappa] = geom_mean(D_single[., kappa])

# Single Y:  top-5 Optimize Y1  + top-2 Explore Y1   (no "Optimize All")
# Multi  Y:  top-2 per Y (Optimize) + top-3 All (Optimize) + top-2 per Y (Explore)
combined = assemble(scopes per §8.3,
                    dedupe by (Scope, X values),
                    order by mode_key / target_key / RankInScope,
                    renumber cand1..N,
                    round 4 dp)

# §9: Save Result Excel
# Augment Data sheet with auto_quad columns (§9.0)
sheets_list[["Data"]] = augment_data_with_auto_quad(sheets_list[["Data"]], fits)
sheets_list[["Fit info"]] = stack(build_fit_info_lines(fits[[yn]]) for yn in Y_names)
if nrow(combined) > 0: sheets_list[["Optimize"]] = combined
write_xlsx(sheets_list, path = sprintf("%s_%s.xlsx",
                                       tools::file_path_sans_ext(basename(upload_path)),
                                       format(Sys.time(), "%Y%m%d%H%M")))
```

---

## 12. Reference Output (Sample8 for numerical verification)

### 12.1 Input
`Sample8.xlsx` — `X1..X5` continuous (integer steps 0..10, so `length.out` fallback gives 11 points each), Y1, Purpose = `">0"`, n_train = 20. No Derived sheet, "Auto 2nd-order terms" checkbox unchecked.

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
(No `[Auto-selected 2nd-order terms]` section because checkbox is off.)

### 12.3 Expected characteristics of the `Optimize` sheet (partial)
- `combined` should have **roughly 12–16 rows** (sampled from LHS 100 pts + 32 corner pts = 132 pts)
- All rows may show `Score = 1.0000` (because the linear term saturates at `X1=X2=0`)
- Column order: `Candidate, Scope, Rank, Score, X1, X2, X3, X4, X5, Pred.Y1, SD.Y1`
- Single Y → Scope order: `Optimize Y1 → Explore Y1` (**no `Optimize All`**); within each scope, ascending `Rank`
- `Candidate` is a sequential label `cand1, cand2, ...` (corresponding to the above ordering)
- `Optimize Y1` contains **5 candidates** (Rank 1–5); `Explore Y1` contains **2 candidates** (Rank 1–2)

**Verification checkpoints**:
- `Fit info` values for `(intercept), X1, X2` **exactly match** `+21.559403, -2.896958, -3.629749` → prior scale conversion in §2 is correct
- Candidate count in `Optimize` sheet is **≤ 132** → LHS + corners in §4 is correct (not the 74,519-row full grid)
- No `Optimize All` row in `Scope` column → single-Y branch is correct

---

## 13. Pitfalls

- **Using `100·I` directly in standardized scale gives different numbers.** Always pass through `prior_to_standardized_scale()`.
- **Keep candidates to ≤ 2,148 points** using LHS + corners. Do not build a full grid with `expand.grid` — it explodes with large `d` and changes results.
- Call `set.seed(1)` exactly once, immediately before §4.3. Do not use any random calls inside the fit loop.
- Skip corner addition when `MAX_CORNERS = 2048` is exceeded (occurs when `d_cont ≥ 12` continuous variables).
- If no categorical variables, pass `Z_cat = NULL` / `Z_cat_new = NULL` to both fit and predict.
- **Use `var_total = sigma2 + v_gp + v_beta`** for prediction variance. Using only `v_gp` will not match the app.
- `Fit info` values for `R²/RMSE/eps var` must be recomputed from `yorg - y_pred` in original scale (not `fit$R2`).
- Candidate table column names follow **`paste0("Pred.", Y)` / `paste0("SD.", Y)`** exactly.
- The output Excel preserves all original sheets in their original order, with `Data` augmented, then `Fit info` and `Optimize` appended.
- **Auto 2nd-order term names must be stored with `check.names = FALSE`**. If R's default name mangling is applied (e.g. `as.data.frame(...)` without `check.names=FALSE`), `"X1*X3"` becomes `"X1.X3"` and the formula lookup breaks, leaving the prediction column as `NA`.
- **Auto 2nd-order candidates that duplicate a user-defined derived column are skipped** (checked by name against `derived_cols` before adding to `candidates`).
- **`all_cont` differs per Y** when auto 2nd-order terms are active: prediction and standardization must use each Y's own `all_cont`, `std`, and `fit`.
- **"Optimize All" is omitted when there is exactly one Y** (it would be identical to "Optimize Y1"). In the single-Y case, "Optimize Y1" returns **5 candidates** instead of 2.
- The filename timestamp follows `format(Sys.time(), "%Y%m%d%H%M")` (local time, minute precision).
