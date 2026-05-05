# AutoXP3 AI用プロンプト：Excelファイル に対する最適化と「Save Result」形式の Excel 出力

このプロンプトは、別の AI（または人間）が同じ手順を再現できるように、**R コード内で使う関数とその入出力**だけを記述したものです。実装コード（数式や具体的なベクトル演算）は含みません。前提として、AI には Excel ファイル **1 つだけ** を渡します。最終成果物は、Shiny アプリAutoXP3の **「Save Result」ボタン** が出力する Excel と同じ形式の `.xlsx` です。

---

## 全体像（擬似コード・最小版）

```text
# 入力: input.xlsx  （Definition / Data シート必須）
# 出力: <元名>_<YYYYMMDDHHMM>.xlsx  （元シート全部 + Fit info + Optimize）

# 1) 読み込み
defs, data, all_sheets  = read_excel(input.xlsx)
X_cont, X_cat, Y_names  = parse Definition
purposes                = parse_purpose(Y 行の Purpose)       # §1

# 2) 各 Y についてベイズ半パラメトリック回帰をフィット
for yn in Y_names:
    std       = standardize_fit(X=cbind(1,X_cont_train), Z=X_cont_train, y=data[yn])
    prior_std = prior_to_standardized_scale(mu0=0, sig0=100, std)  # 原スケール prior を標準化へ
    fit       = fit_semiparam_bayes(std$y, std$X, std$Z, Z_cat,
                                    mu0=prior_std$mu0, Sigma0=diag(prior_std$sig0),
                                    sigma2=0.05, ell=0.4, sf2=1.0, sigma_cat2=0.5)
    beta      = beta_to_original_scale(fit$mu_beta, std)            # 表示用 β
    y_pred    = predict_semiparam_bayes(fit, 訓練X) を原スケールへ     # R²/RMSE 再計算用

# 3) 候補集合を作る（アプリ完全再現：LHS 100 点 + コーナー ≤ 2048 点）
set.seed(1)
cand_list = 各変数の 1D 候補 (連続=seq(..., by=h) or length.out=21, カテゴリ=全水準)
grid_df   = if prod(|cand_list|) ≤ 100:   expand.grid(cand_list)
            else:                         LHS(n=100) 連続+カテゴリ
grid_df   = unique(rbind(grid_df, 全変数の(min,max)コーナー))   # コーナー総数 ≤ 2048 のときのみ

# 4) 候補に対して各 Y の (μ, σ) を予測
for yn:  all_mu[yn], all_sd[yn] = predict_semiparam_bayes(...) を原スケールへ
          (分散は var_total = σ² + v_gp + v_beta を使う)

# 5) UCB → Desirability → スコープ取得
for kappa in (0, 2):                        # Optimize=0, Explore=2
    D_single[yn, kappa] = minmax(ucb_score(μ, σ, Purpose, kappa))
    D_all[kappa]        = geomean(D_single[:, kappa])
scopes =  各 Y top-3 (Optimize) + All top-5 (Optimize)
        + 各 Y top-3 (Explore)  + All top-5 (Explore)

# 6) 候補テーブルを結合・重複除去・ナンバリング
combined = rbind(scopes) → uniq by (Mode, TargetY, X値)
                         → order by Mode, TargetY, Rank
                         → Candidate = cand1..N
                         → round(数値, 4)

# 7) Save Result 形式で書き出し
sheets = [元シート全部] + [Fit info:各 Y の build_fit_info_lines()] + [Optimize:combined]
write_xlsx(sheets, "<base>_<YYYYMMDDHHMM>.xlsx")
```

詳細は以下の §0〜§13。検証用の数値例は §12（Sample8）。

---

## 0. 前提

- **入力**: ユーザーが渡す Excel `input.xlsx` 1 ファイル
  - 必須シート: `Definition`、`Data`
  - 任意シート: `Note`、`Candidate` など（あればそのまま保持）
- **R コード一式**: `myapp/R/`
  - `utils.R` … パース・グリッド生成
  - `standardize.R` … 標準化／逆標準化／事前分布スケール変換
  - `semiparam_bayes.R` … 半パラメトリックベイズ回帰の fit/predict
  - `kernel.R` … RBF カーネル
  - `categorical-kernel.R` … カテゴリ用デルタカーネル
  - `optimize_ucb.R` … UCB 獲得関数（`ucb_score`）
  - `server.R` … Shiny サーバ側のスコープ生成・Save Result 書き出し（`compute_D`, `compute_single_y_desirability`, `make_scope_df`, `build_fit_info_lines`, `download_model`）
- **既定ハイパラ（アプリと同じ）**
  - `ell = 0.4`（RBF 長さスケール = `theta2`）
  - `sf2 = 1.0`（RBF 信号分散 = `theta1`）
  - `sigma2 = 0.05`（観測ノイズ分散）
  - `sigma_cat2 = 0.5`（カテゴリカーネル分散）
  - 事前分布: **原スケールで** `β ~ N(0, 100·I)`
  - `kappa`: Optimize=0、Explore=2
- **乱数シード**: 候補生成の LHS 直前に **`set.seed(1)` を必ず呼ぶ**（アプリと同じ）

---

## 1. 入力 Excel の読み込み

**入力**: `input.xlsx` のパス
**出力**: 連続変数名 `X_cont`、カテゴリ変数名 `X_cat`、目的変数名 `Y_names`、各変数の Min/Max/Interval/Purpose、訓練データ `(X_train, Y_train)`。

シート仕様:
- `Definition`: 列ごとに `Parameter / Type(continuous|categorical|Y) / Min_raw / Standard_raw / Max_raw / Interval / Purpose`
- `Data`: 訓練データ（各行 = 1 サンプル、列 = X と Y）

**Purpose の適用対象（重要）**: Purpose は **Y 行のみ** 参照する。X 行の Purpose は無視。Y の Purpose が `NA` または空文字なら `type="none"`（純粋探索）扱い。

`Purpose` 文字列のパース:
> **`utils.R :: parse_purpose(p)`**
> - 入力: 文字列（例 `">0"`, `"<=5"`, `"=10"`, `"7"`、全角＜＞＝も可）
> - 出力: `list(type, op, value)` … `type ∈ {bound, target, none, unknown}`

連続変数の 1D 候補リスト（**アプリの server.R:1202–1208 と完全一致**）:
- `Interval` が有限かつ `> 0` → `seq(min, max, by = Interval)`
- それ以外 → `seq(min, max, length.out = 21)`（**21 点**）
- 長さ < 2 なら `c(min, max)`

カテゴリ変数の水準取得:
> **`utils.R :: get_cat_levels(def_row)`**
> - 入力: Definition の 1 行
> - 出力: 重複除去された水準ベクトル（順序は `Min_raw, Standard_raw, Max_raw` から取得した順）

---

## 2. 標準化と事前分布のスケール変換

**目的**: アプリと同じ数値結果を得るために、線形係数の事前分布は **原スケール** で `β ~ N(0, 100·I)` を指定し、推定時は標準化スケールへ変換して使う。

> **`standardize.R :: standardize_fit(X, Z, y, standardize_X=TRUE, intercept_col=1L)`**
> - 入力: 計画行列 `X = cbind(1, X_cont_train)`、生の連続変数行列 `Z = X_cont_train`、目的変数 `y`
> - 出力: `list(X, Z, y, y_mean, y_sd, Z_mean, Z_sd, X_mean, X_sd, ...)`

> **`standardize.R :: prior_to_standardized_scale(mu0_orig, sig0_orig, std, all_cont)`**
> - 入力: `mu0_orig = rep(0, p)`, `sig0_orig = rep(100, p)`, 上記 `std`, `all_cont = X_cont`
> - 出力: `list(mu0, sig0)`（標準化スケール。`fit_semiparam_bayes` に `mu0=prior$mu0, Sigma0=diag(prior$sig0)` で渡す）

> **`standardize.R :: standardize_apply(Xnew, Znew, std)`**
> - 予測時に新しい `(Xnew, Znew)` を訓練と同じスケーリングへ変換

> **`standardize.R :: beta_to_original_scale(mu_beta_std, std, all_cont)`**
> - 推定後の `β` を原スケールへ復元。**Save Result の `Fit info` と線形式表示には必ずこの出力を使う**。

> **`standardize.R :: destandardize_y(mu_s, std)` / `destandardize_y_sd(sd_s, std)`**
> - 予測平均・SD を元スケールへ復元

---

## 3. 半パラメトリックベイズ回帰のフィット（各 Y ごと）

> **`semiparam_bayes.R :: fit_semiparam_bayes(y, X, Z, Z_cat, mu0, Sigma0, sigma2, ell, sf2, sigma_cat2, jitter=1e-8)`**
> - モデル: `y = Xβ + u + ε`、`β ~ N(mu0, Sigma0)`、`u ~ GP(0, K_RBF + K_cat)`、`ε ~ N(0, σ²·I)`
> - カーネル: `kernel.R :: rbf_kernel(Z1, Z2, ell, sf2)` と `categorical-kernel.R :: additive_delta_kernels(Z_cat, sigma2=sigma_cat2)`（列ごとにデルタカーネルを加算）
> - 入力: 標準化された `y, X, Z`。カテゴリが無ければ `Z_cat = NULL`、ある場合は `data.frame` で列名 = `X_cat`、各列は `as.character`
> - 出力: `fit` オブジェクト（`mu_beta, Sigma_beta, L, V, K, y_hat, u_hat, eps_hat, eps_var_hat, rmse_total, R2, ...`）

各 Y について `fit_wrap` を保持する。最小限のフィールド:
```
fit_wrap = list(
  fit = <fit object>,
  std = <standardize_fit output>,
  lambda = NULL,                          # Yeo-Johnson は既定で無効
  y_name = <Y name>,
  all_cont = X_cont,
  mu_beta_orig = beta_to_original_scale(fit$mu_beta, std, X_cont),
  yorg = <original-scale y_train>,
  y_pred = <original-scale prediction on training X, see §6>
)
```

---

## 4. 候補集合の生成（アプリ完全再現、server.R 1194–1248）

**方針**: 全格子 `expand.grid` は使わない。アプリは LHS + コーナー点で候補を **おおむね 2,148 点以下** に抑えている。

### 4.1 変数ごとの 1D 候補 `cand_list`
各 `X_i` について §1 の規則で作る（連続は `seq(..., by=h)` か `seq(..., length.out=21)`、カテゴリは `get_cat_levels()`）。

### 4.2 総積チェック
`n_all = prod(sapply(cand_list, length))`

### 4.3 本体サンプリング
- **`n_all <= 100`**: `grid_df = expand.grid(cand_list, KEEP.OUT.ATTRS=FALSE, stringsAsFactors=FALSE)`
- **`n_all > 100`**:
  1. `set.seed(1)` を呼ぶ
  2. `grid_df` を `N_SAMPLE = 100` 行の空データフレームとして用意
  3. カテゴリ各列: `sample(cand_list[[nm]], size=100, replace=TRUE)` を割り当て
  4. 連続変数があれば Latin Hypercube Sampling:
     - `lhs_unit(n, d)`: 各列 `j` について `perm = sample.int(n, n, replace=FALSE)`、`U[,j] = (perm - runif(n)) / n`
     - 生成した `U[,j]` を `cand_list[[nm]]` の離散値に丸める: `vv[pmin(m, pmax(1, floor(U[,j]*m) + 1L))]`（`m = length(vv)`）

### 4.4 コーナー点の追加
- `ext_list = lapply(Xnames, function(nm) { vv <- cand_list[[nm]]; c(vv[1], vv[length(vv)]) })`
  （連続なら `(min, max)`、カテゴリなら `(最初, 最後)` の水準）
- `n_corners = prod(sapply(ext_list, length))`
- **`n_corners <= MAX_CORNERS = 2048`** のときのみ:
  `grid_df = unique(rbind(grid_df, expand.grid(ext_list, KEEP.OUT.ATTRS=FALSE, stringsAsFactors=FALSE)))`
- `2048` を超える場合はコーナー追加をスキップ

### 4.5 派生変数と制約
- `derived_cols`（もしユーザ指定があれば）: `grid_df[[col]] <- eval(parse(text=formula_str), envir=grid_df)`
- `constraints`（制約式リスト）: 各式を `eval(parse(text=expr), envir=as.list(grid_df))` → `keep` に AND で積む → `grid_df <- grid_df[keep, ]`

### 4.6 予測用の分解
- `Xnew_cont = as.matrix(grid_df[, X_cont_all])`（型 double）。`X_cont_all = c(X_cont, derived_cols)`
- `Z_cat_new = data.frame(grid_df[, X_cat])` → 各列 `as.character()`。カテゴリ無しなら `NULL`
- `Xnew = cbind(1, Xnew_cont)`、`Znew = Xnew_cont`

---

## 5. 候補に対する予測

各 Y について:
```
ns = standardize_apply(Xnew, Znew, std)
pr = predict_semiparam_bayes(fit, Xnew=ns$X, Znew=ns$Z,
                             Z_cat_new = Z_cat_new,
                             return_components = TRUE)
all_mu[[yn]] = destandardize_y   (pr$mean,             std)
all_sd[[yn]] = destandardize_y_sd(sqrt(pmax(pr$var_total, 0)), std)
```

※ `var_total = sigma2 + v_gp + v_beta`（観測ノイズ分散込み）を使うこと。`v_gp` だけを使うと SD が小さくなり、アプリと乖離する。

---

## 6. 訓練データ上の予測（`Fit info` の R²/RMSE 用）

`build_fit_info_lines` は **原スケールの残差** `yorg - y_pred` から `eps var, RMSE, R²` を再計算する。したがって `fit$R2` や `fit$rmse_total` をそのまま使ってはいけない。

```
pr_tr  = predict_semiparam_bayes(fit, Xnew=fit$X, Znew=fit$Z,
                                  Z_cat_new=fit$Z_cat, return_components=FALSE)
y_pred = destandardize_y(pr_tr$mean, std)   # original scale
# lambda=NULL 前提なので inv_y は恒等
```

そのうえで:
```
resid_o      = yorg - y_pred
eps_var_orig = var(resid_o)                       # R の var(): (n-1) 分母
rmse_orig    = sqrt(mean(resid_o^2))
ss_res       = sum(resid_o^2)
R2_orig      = 1 - ss_res / sum((yorg - mean(yorg))^2)
```

---

## 7. UCB と Desirability（server.R 1314–1349 と完全一致）

### 7.1 `optimize_ucb.R :: ucb_score(mu, sd, purpose, kappa)` の分岐
- Purpose = `"="` または target（`type="target"`） → `score = -|mu - target| + kappa·sd`
- Purpose が bound 以外（`none`, `unknown` 含む） → `score = mu + kappa·sd`
- Purpose = `">"`, `">="` → `score = (mu - thr) + kappa·sd`
- Purpose = `"<"`, `"<="` → `score = (thr - mu) + kappa·sd`
- `sd` は `pmax(sd, 1e-12)` でクリップ

### 7.2 単一 Y の Desirability（`kappa` ごとに**毎回**計算）
```
score_y = ucb_score(all_mu[[yn]], all_sd[[yn]], purp_y, kappa)
lo = min(score_y); hi = max(score_y)
if (hi > lo)   D_single[yn] = clip((score_y - lo) / (hi - lo), 0, 1)
else           D_single[yn] = rep(0.5, length(score_y))
```

### 7.3 全 Y 統合 Desirability
```
D_mat = cbind(D_single[Y1], D_single[Y2], ...)   # 各 Y の単独 Desirability
D_all = apply(D_mat, 1, function(row) prod(pmax(row, 1e-6))^(1 / ncol(D_mat)))
```
（幾何平均。各要素は 1e-6 で下限クリップ）

**重要**: `kappa=0` と `kappa=2` で **score も D_single も D_all も全て作り直す**。

---

## 8. スコープ抽出と候補テーブル結合（server.R 1357–1429）

### 8.1 `base_df` の構築
```
base_df = grid_df[, Xnames]
for yn in Y_names:
    base_df[[paste0("Pred.", yn)]] = all_mu[[yn]]
    base_df[[paste0("SD.",   yn)]] = all_sd[[yn]]
```
列名は **`paste0("Pred.", Y 名)` / `paste0("SD.", Y 名)`**（Y 名はそのまま使う）。

### 8.2 `make_scope_df(mode, target_y, desirability, n_top)`
```
tmp = base_df
tmp$Desirability = desirability
tmp$Mode = mode
tmp$TargetY = target_y
tmp = tmp[order(tmp$Desirability, decreasing = TRUE), ]   # R の order() デフォルト
tmp = head(tmp, n_top)
tmp$RankInScope = 1..nrow(tmp)
return tmp
```

### 8.3 スコープ取得の順序
```
result_list = list()
for yn in Y_names:
    result_list[["opt_" + yn]] = make_scope_df("Optimize", yn, D_single[yn](kappa=0), 3)
result_list[["opt_all"]]       = make_scope_df("Optimize", "All", D_all(kappa=0),     5)
for yn in Y_names:
    result_list[["exp_" + yn]] = make_scope_df("Explore", yn, D_single[yn](kappa=2), 3)
result_list[["exp_all"]]       = make_scope_df("Explore", "All", D_all(kappa=2),     5)
combined = do.call(rbind, result_list)
```

### 8.4 重複除去・並び替え・ナンバリング
```
# スコープ間で (Mode, TargetY, Xnames) が同じなら重複扱い
key = paste(combined$Mode, combined$TargetY, combined[, Xnames], sep = "\r")
combined = combined[!duplicated(key), ]

# Mode → TargetY → RankInScope の順で並べ替え
combined$Mode    = factor(combined$Mode,    levels = c("Optimize", "Explore"))
combined$TargetY = factor(combined$TargetY, levels = c(Y_names, "All"))
combined = combined[order(combined$Mode, combined$TargetY, combined$RankInScope), ]

# 最終 Candidate 名（通し番号、行順）
combined = cbind(Candidate = sprintf("cand%d", seq_len(nrow(combined))), combined)

# 列名変更: RankInScope → "Rank in scope"
names(combined)[names(combined) == "RankInScope"] = "Rank in scope"

# 数値列は整数の "Rank in scope" を除いて小数 4 桁に丸め
for col in numeric cols except "Rank in scope":
    combined[[col]] = round(combined[[col]], 4)
combined[["Rank in scope"]] = as.integer(...)
```

**最終列順**:
`Candidate, <Xnames...>, Pred.Y1, SD.Y1, ..., Pred.Yk, SD.Yk, Desirability, Mode, TargetY, Rank in scope`
（`cbind(Candidate, base_df$X..., base_df$Pred/SD..., Desirability, Mode, TargetY, Rank in scope)` の順）

---

## 9. 「Save Result」形式の Excel を書き出す（server.R 807–861 と完全一致）

**ファイル名**: `<元ファイル名(拡張子なし)>_<YYYYMMDDHHMM>.xlsx`（ローカル時刻）

**シート構成（順序も同じ）**:
1. **元 Excel の全シートをそのまま転記**。`readxl::excel_sheets()` で順序を取り、`readxl::read_excel()` で各シートを `data.frame` として読み、`writexl::write_xlsx()` で書き戻す。**書式・数式・結合セル・日付書式は保持しない**（型は `read_excel` が推論したものを採用）。
2. **`Fit info` シート（新規）**: 列 = `Output, Line`。各 Y について `build_fit_info_lines(fit_wrap)` の出力を縦に積む。`Output` 列の先頭セルのみ `Y` 名、残りは空文字。各 Y ブロックの末尾に空行 1 つ。
3. **`Optimize` シート**: `combined`（§8 で作った候補テーブル）を書き出す。候補が空なら **このシートは作らない**。

### 9.1 `build_fit_info_lines(fit_wrap)` の逐語出力仕様

`sprintf` フォーマットは下記を **そのまま再現** する必要がある（中点 `·`、σ²、ギリシャ文字 ε など Unicode をそのまま使う）。

```
Semi-parametric Bayesian regression
<Yname> = <β0:%.4f>·1 + <β1:%.4f>·X1 + ... + <βp:%.4f>·<Xp名> + u + ε
beta ~ N(mu0, Sigma0),  u ~ GP(0, K),  ε ~ N(0, σ² I)

[Posterior beta | y] (original scale)
  mu_beta[1]  ((intercept))        = <+%.6f>
  mu_beta[2]  (X1)                 = <+%.6f>
  ...
  mu_beta[p+1] (<Xp名>)            = <+%.6f>

[Hyperparameters]
theta1 (RBF scale)       = <%.4f>
theta2 (lengthscale)     = <%.4f>
sigma2 (noise var)       = <%.6f>
sigma_cat (cat. var.)    = <%.6f>

[Residuals] (original scale)
eps var.= <%.4f>,  RMSE = <%.4f>,  R2 = <%.4f>
```

書式細目（`sprintf` の仕様そのまま）:
- 線形式の各項: `"%.4f·<Xname>"` を `" + "` で連結。先頭項だけ `"%.4f·1"`（intercept）
- `mu_beta` ブロック: `sprintf("  mu_beta[%d]  %-20s = %+.6f", i, paste0("(", x_labels[i], ")"), beta[i])`
  - `%-20s` は左詰め 20 文字。ラベルは intercept のみ `"((intercept))"`、他は `"(Xname)"`
  - `%+.6f` は符号必須の 6 桁小数（正値は `+`, 負値は `-`）
- `theta1`/`theta2` は `%.4f`、`sigma2`/`sigma_cat` は `%.6f`
- 残差行は `%.4f`

---

## 10. 乱数・丸め・数値精度

- LHS の `set.seed(1)` は §4.3 の**直前に 1 回だけ**呼ぶ（他の場所では呼ばない）
- 候補テーブル `combined` の数値列は最終的に `round(x, 4)` 済み（`Rank in scope` を除く）
- `Fit info` の数値表示は §9.1 の `sprintf` 書式どおり
- Cholesky のジッタは `jitter = 1e-8`（`fit_semiparam_bayes` の既定）

---

## 11. 全体フロー（擬似コード）

```text
upload_path = "input.xlsx"
set.seed(1)                             # 全体の再現性のため先に設定してもよい

# §1: パース
all_sheets = excel_sheets(upload_path)
sheets_list = lapply(all_sheets, read_excel, path = upload_path)
defs        = Definition  sheet
data        = Data        sheet
X_cont, X_cat, Y_names, purposes = parse defs (Purpose は Y 行のみ)
cand_list   = per-variable 1D lists (§4.1)

# §2-§3: 各 Y の fit
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
    # §6: 訓練上の予測（Fit info の R²/RMSE 用）
    pr_tr     = predict_semiparam_bayes(fit, fit$X, fit$Z, fit$Z_cat, FALSE)
    y_pred_o  = destandardize_y(pr_tr$mean, std)
    fits[[yn]] = fit_wrap(fit, std, lambda=NULL, y_name=yn, all_cont=X_cont,
                          mu_beta_orig=beta_orig, yorg=y_train_o, y_pred=y_pred_o)

# §4: 候補生成（アプリ完全再現）
set.seed(1)
grid_df   = lhs_plus_corners(cand_list, N_SAMPLE=100, MAX_CORNERS=2048)
apply derived_cols / constraints (§4.5)
Xnew, Znew, Z_cat_new = split (§4.6)

# §5: 予測
for yn in Y_names:
    ns = standardize_apply(Xnew, Znew, fits[[yn]]$std)
    pr = predict_semiparam_bayes(fits[[yn]]$fit, ns$X, ns$Z, Z_cat_new, return_components=TRUE)
    all_mu[yn] = destandardize_y   (pr$mean,                    fits[[yn]]$std)
    all_sd[yn] = destandardize_y_sd(sqrt(pmax(pr$var_total, 0)),fits[[yn]]$std)

# §7-§8: UCB / Desirability / スコープ
for kappa in (0, 2):
    for yn in Y_names: D_single[yn, kappa] = ...
    D_all[kappa] = geom_mean(D_single[., kappa])
combined = assemble(Optimize κ=0 top-3 per Y + top-5 All,
                    Explore  κ=2 top-3 per Y + top-5 All,
                    dedupe,
                    order by Mode/TargetY/RankInScope,
                    renumber candN,
                    round 4 dp)

# §9: Save Result Excel
sheets_list[["Fit info"]] = stack(build_fit_info_lines(fits[[yn]]) for yn in Y_names)
if nrow(combined) > 0: sheets_list[["Optimize"]] = combined
write_xlsx(sheets_list, path = sprintf("%s_%s.xlsx",
                                       tools::file_path_sans_ext(basename(upload_path)),
                                       format(Sys.time(), "%Y%m%d%H%M")))
```

---

## 12. 参考出力例（Sample8 で検証用）

### 12.1 入力
`Sample8.xlsx` — `X1..X5` 連続（各 0..10 整数間隔、`length.out` のフォールバックで 11 点）、Y1、Purpose = `">0"`、n_train = 20。

### 12.2 期待される `Fit info` シート中身（Y1 ブロック）
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

### 12.3 期待される `Optimize` シートの特徴（部分）
- 候補数 `combined` は **約 12〜16 行**（§4 の LHS 100 点 + コーナー 32 点 = 132 点から抽出）。
- すべての行の `Desirability` が 1.0000 に張り付くことがある（β の線形式が `X1=X2=0` で飽和するため）。
- 列順: `Candidate, X1, X2, X3, X4, X5, Pred.Y1, SD.Y1, Desirability, Mode, TargetY, Rank in scope`
- `Mode` は `Optimize` → `Explore` の順、各 `Mode` 内では `TargetY = Y1 → All`、`Rank in scope` 昇順。
- `Candidate` は `cand1, cand2, ...` の通し番号（上記並びに対応）。

**検証ポイント**:
- Fit info の `(intercept), X1, X2` が `+21.559403, -2.896958, -3.629749` に**完全一致** → §2 の prior 変換が正しい
- `Optimize` の候補数が **132 点以下** → §4 の LHS+コーナーが正しい（フル格子の 74,519 点ではない）

---

## 13. 注意点

- **事前分布を標準化スケールの `100·I` で直接使うと数値が変わる**。必ず `prior_to_standardized_scale()` を経由する。
- **候補生成は LHS + コーナーで 2148 点以下に抑える**。`expand.grid` でフル格子を作ってはいけない（d が増えると爆発するし、結果も変わる）。
- `set.seed(1)` を §4.3 の直前に 1 回だけ呼ぶ。他の乱数呼び出しで順序が狂わないよう、fit ループ内で乱数を使わないこと。
- `MAX_CORNERS = 2048` を超える場合はコーナー追加をスキップ（連続 d_cont ≥ 12 で発生）。
- カテゴリが無ければ fit / predict の両方で `Z_cat = NULL` / `Z_cat_new = NULL` を渡す。ある場合は `data.frame` + `as.character`。
- 予測分散は **`var_total = sigma2 + v_gp + v_beta`** を使う。`v_gp` のみではアプリと一致しない。
- `Fit info` の `R²/RMSE/eps var` は `yorg - y_pred` から原スケールで再計算する（`fit$R2` ではない）。
- 候補テーブルの列名は **`paste0("Pred.", Y)` / `paste0("SD.", Y)`**。Y 名に特殊文字が入っている場合もそのまま貼る。
- 出力 Excel は元シートを順序ごと保持し、末尾に `Fit info`→`Optimize` の順で追加。
- ファイル名のタイムスタンプは `format(Sys.time(), "%Y%m%d%H%M")` 相当（ローカル時刻、分単位）。
