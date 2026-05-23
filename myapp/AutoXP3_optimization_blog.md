# Dissecting AutoXP3's Optimization Engine — What 10-Sample Verification Reveals

> This article is based on an independent analysis of AutoXP3's ten benchmark sample files (`Sample1.xlsx` through `Sample10.xlsx`), cross-referencing the app's optimization recommendations against the ground-truth conditions recorded in each file's Note sheet. The algorithm description is derived from the REPRODUCTION_PROMPT.md specification and reverse-engineering of app behavior — this is not official AutoXP3 documentation.

---

## 1. Model Architecture

AutoXP3 runs a **semi-parametric Bayesian regression** model internally:

```
Y = Xβ + u + ε
β  ~ N(0, 100·I)                              prior on linear coefficients (original scale)
u  ~ GP(0, K_RBF(ℓ=0.4) + K_cat(σ²=0.5))    Gaussian Process for nonlinear residuals
ε  ~ N(0, σ²=0.05)                            observation noise
```

The linear term `Xβ` captures the global trend — main effects plus any explicitly modeled derived variables (e.g., interactions added as columns in the Derived sheet). The GP `u` absorbs whatever the linear part cannot explain: nonlinearity, curvature, and local variation. Categorical variables are handled via a separate additive delta kernel `K_cat`.

For optimization, AutoXP3 uses **UCB (Upper Confidence Bound)** scoring:

| Mode | κ | Score formula | Behavior |
|------|---|---------------|----------|
| Optimize | 0 | μ (or target-adjusted) | Pure exploitation — best predicted value |
| Explore | 2 | μ + 2σ | Prefers high-uncertainty regions |

---

## 2. Candidate Generation and Scope Structure

AutoXP3 evaluates candidates over a **Latin Hypercube Sample (LHS) of 100 points** plus all corner points (min/max combinations of each variable, up to 2,048), then selects top candidates per scope:

**Single-output (1 Y):**
- `Optimize Y1` — top 5 candidates (κ = 0)
- `Explore Y1` — top 2 candidates (κ = 2)
- *(No "Optimize All" — it would be identical to "Optimize Y1")*

**Multi-output (2+ Y):**
- `Optimize Yi` — top 2 per Y (κ = 0)
- `Optimize All` — top 3 by geometric-mean desirability (κ = 0)
- `Explore Yi` — top 2 per Y (κ = 2)

---

## 3. Auto 2nd-Order Terms

AutoXP3 includes an **"Auto 2nd-order terms"** checkbox. When enabled, fitting becomes a two-stage procedure:

**Stage 1** — fit the ordinary 1st-order model (base X + any user-defined derived variables).

**Stage 2** — automatically select up to 3 quadratic or interaction terms and refit:
1. Identify *important* variables: those whose |β| ≥ 20% of max|β| in the Stage 1 fit.
2. Generate candidates: Xi² for each important variable; Xi·Xj for each important pair (both must be important — **strong heredity**).
3. Filter: keep only candidates whose absolute correlation with the Stage 1 residuals is ≥ 0.30.
4. Select the top 3 by correlation and refit with those terms appended.

The key constraint is the 0.30 correlation threshold. It prevents spurious detection but also means that 2nd-order terms with weak residual correlation (e.g., because training data doesn't cover the nonlinear region) won't be automatically captured.

---

## 4. Sample-by-Sample Analysis

### Sample 1 — Simple Linear, Single Variable

**Data** — 10 training observations. One continuous variable X1 ∈ [0, 10], integer step 1. X1 values span the full range from near 0 to 10, giving good coverage for a 1D problem.

<details>
<summary>Training data (click to expand)</summary>

*(Data stored in Sample1.xlsx. True model: Y1 = 2.0·X1 + 1.0. Approximate X1 range in training: [0.5, 9.8].)*

</details>

**Model** — `Y1 = 2.0·X1 + 1.0` (purely linear)

**Purpose** — Maximize (`>`)

**Analysis** — With a single variable and a linear true model, the semi-parametric model has minimal work to do. The fitted β(X1) ≈ +2.13 (close to the true 2.0; the small deviation reflects the finite GP prior influence). R² ≈ 0.982, RMSE ≈ 0.40 — slightly lower R² than other samples because of proportionally higher noise in this single-variable setting.

The optimum at X1 = 10 is at the boundary of the design space. If any training points appear near X1 = 10, this is **interpolation**; otherwise it is mild **extrapolation** from the highest training X1 value. Either way, the linear fit has no ambiguity: increasing X1 always increases Y1.

**Verdict: ✓ Match** — Optimizer correctly recommends X1 = 10.

---

### Sample 2 — Quadratic in X1, Interior Optimum Found in Two Iterations

**Data** — 10 initial training observations. Two continuous variables X1 ∈ [0, **20**], X2 ∈ [0, 10], integer step 1. The Definition sheet specifies X1 Max = 20, extending the search space well beyond the training data. Training X1 spans [1.97, 7.19] — the region X1 > 7.2 is **entirely unsampled**. X2 spans [1.98, 6.90].

<details>
<summary>Training data — initial 10 points (click to expand)</summary>

| id | X1 | X2 | Y1 |
|---|---|---|---|
| 1 | 4.71 | 6.90 | 26.8192 |
| 2 | 5.62 | 1.98 | 18.3751 |
| 3 | 5.72 | 2.80 | 20.1483 |
| 4 | 6.23 | 4.60 | 24.3654 |
| 5 | 2.48 | 4.97 | 18.1379 |
| 6 | 3.74 | 5.13 | 21.4265 |
| 7 | 5.31 | 2.90 | 19.7768 |
| 8 | 2.26 | 2.97 | 13.5545 |
| 9 | 1.97 | 3.84 | 14.4958 |
| 10 | 7.19 | 4.05 | 24.1448 |

</details>

**Model** — `Y1 = 3.6·X1 + 2.0·X2 − 0.2·X1² + 0.5`

**Purpose** — Maximize (`>`)

**Analysis** — The −0.2·X1² term creates an **interior optimum**: ∂Y/∂X1 = 3.6 − 0.4·X1 = 0 gives the true optimal X1 = 9. X2 = 10 is always optimal (positive coefficient). With X1 Max extended to 20, the optimizer now searches a much wider space.

**True optimum: X1 = 9, X2 = 10, Y1 = 36.7**

**Round 1 — linear extrapolation to new boundary.** The 10 initial training points are confined to X1 ≤ 7.19. With no training data in the region X1 > 7.2, the GP at X1 = 20 reverts entirely to the linear prediction (RBF correlation ≈ exp(−huge) ≈ 0). The 1st-order model's β(X1) ≈ +1.86 is monotonically increasing, so the model predicts high Y at the new boundary X1 = 20. The optimizer's first suggestion is **X1 = 20, X2 = 10** (Pred.Y1 ≈ 60+, grossly overpredicting the true Y1 = 12.5 at that point).

**Experimental evaluation.** The user runs an experiment at X1 = 20, X2 = 10 and observes the actual result: **Y1 = 12.5** — far below the model's prediction and even below most training values. This large negative surprise reveals that the response turns over well before X1 = 20.

**Round 2 — curvature detected, interior optimum found.** After adding the X1 = 20 data point to the Data sheet and re-running the app, the picture changes dramatically. The first-order residual at the new point is enormous (predicted ≈ 60, actual = 12.5, residual ≈ −48). The X1² value at this point is 400 — the largest in the dataset by far. The absolute correlation between X1² and the first-order residuals now **far exceeds the 0.30 threshold**, triggering automatic selection of X1² as a 2nd-order term. With the quadratic curvature now explicitly modeled, the optimizer correctly identifies **X1 = 9, X2 = 10** as the top candidate (Y1 = 36.7).

This two-round sequence is a textbook illustration of the Optimize → Evaluate → Re-optimize workflow: the first suggestion probes the unexplored boundary; the surprising result teaches the model the quadratic shape; the second suggestion homes in on the true interior optimum.

**Verdict: ✓ Match (2nd iteration)** — First suggestion X1 = 20 reveals the quadratic decline; after adding that data point, the model correctly finds X1 = 9, X2 = 10

---

### Sample 3 — Unmodeled Interaction, Counterintuitive Signs

**Data** — 10 training observations. Two continuous variables X1, X2 ∈ [0, 10], integer step 1. Training X1 spans [2.16, 7.58]; X2 spans [2.09, 8.25]. Y1 values in training are almost entirely **negative** (range −20.70 to +1.66), yet the true global maximum is Y1 = 20 at X1 = 10, X2 = 0 — far outside the training response range.

<details>
<summary>Training data (click to expand)</summary>

| id | X1 | X2 | Y1 |
|---|---|---|---|
| 1 | 3.54 | 5.28 | −7.27 |
| 2 | 2.16 | 8.25 | −4.88 |
| 3 | 6.81 | 2.99 | −5.81 |
| 4 | 6.81 | 2.16 | −0.33 |
| 5 | 4.06 | 2.44 | 0.06 |
| 6 | 3.87 | 2.09 | 1.66 |
| 7 | 3.74 | 3.83 | −3.56 |
| 8 | 7.58 | 4.81 | −20.70 |
| 9 | 2.46 | 6.42 | −4.22 |
| 10 | 6.81 | 4.96 | −18.70 |

</details>

**Model** — `Y1 = 2.0·X1 + 1.5·X2 − 1.2·(X1·X2)` (no Derived column for X1·X2)

**Purpose** — Maximize (`>`)

**Analysis** — The negative interaction term −1.2·(X1·X2) dominates the training data (where X1 and X2 are both in the mid-range) and produces mostly negative Y values. When X1·X2 is not included in the design matrix, the 1st-order linear fit must absorb the interaction's average effect, yielding both fitted β(X1) < 0 and β(X2) < 0 — both variables appear to *decrease* the response.

Despite these misleading signs, **R² = 1.000**: the GP corrects the residuals and learns the true surface shape across the training data. When candidates at X1 = 10, X2 = 0 are evaluated, the GP prediction correctly shows high Y1 (because the GP-encoded surface reveals that setting X2 ≈ 0 removes the destructive interaction). The optimizer correctly identifies X1 = 10, X2 = 0 as the best candidate — a full **extrapolation** (X1 beyond 7.58, X2 below 2.09).

**Key lesson**: Do not interpret negative β as "this variable reduces the output." When the GP fit is excellent (R² ≈ 1), the optimizer's candidate recommendation is more reliable than the sign of β.

**Verdict: ✓ Match** — Optimizer correctly recommends X1 = 10, X2 = 0 (Y1 = 20)

---

### Sample 4 — Sinusoidal Response, Target Purpose

**Data** — 10 training observations. Three continuous variables X1, X2, X3 ∈ [0, 10], integer step 1. X1, X2, X3 values spread across their respective ranges. No Derived sheet.

<details>
<summary>Training data (click to expand)</summary>

*(Data stored in Sample4.xlsx. True model: Y1 = 3.0·sin(X1) + 0.8·X2 + 0.5·X3. Approximate variable ranges: X1 ∈ [1, 9], X2 ∈ [1, 9], X3 ∈ [1, 9].)*

</details>

**Model** — `Y1 = 3.0·sin(X1) + 0.8·X2 + 0.5·X3`

**Purpose** — Hit target `= 5`

**Analysis** — This is the only sample using the target (`=value`) purpose. The UCB score becomes `−|μ − 5| + κ·σ`, rewarding proximity to Y1 = 5 rather than extremes. The fitting itself is excellent (R² ≈ 0.999, RMSE ≈ 0.08) — the semi-parametric model successfully learns the sinusoidal shape, with β(X1) ≈ +0.92 capturing the positive-slope region around the mean.

The difficulty: 3.0·sin(X1) is periodic (period 2π ≈ 6.28). Multiple X1 values produce identical sin values. With 10 training points spread across 3 variables, the optimizer may not precisely resolve which branch of the sine curve to target. The result is a candidate near X1 ≈ π/2 (≈ 1.57) with X2, X3 at their maxima — an **interpolation** point in general but potentially at the boundary of the resolved region for X1.

**Verdict: ~ Partial** — Fit is accurate, but the periodic nature of sin(X1) makes target optimization ambiguous with sparse training data

---

### Sample 5 — Exponential Decay + Categorical Variable

**Data** — 10 training observations. Two continuous variables X1, X2 ∈ [0, 10] and one categorical variable X3 ∈ {A, B, C}. X1 and X2 span their ranges; all three categorical levels appear in training.

<details>
<summary>Training data (click to expand)</summary>

*(Data stored in Sample5.xlsx. True model: Y1 = 4.0·exp(−X1) + 0.8·X2 + cat(A=0, B=1, C=2). Approximate continuous ranges: X1 ∈ [0.5, 9.5], X2 ∈ [0.5, 9.5].)*

</details>

**Model** — `Y1 = 4.0·exp(−X1) + 0.8·X2 + cat(A=0, B=1, C=2)` (minimize)

**Purpose** — Minimize, upper bound `< 10`

**Analysis** — The 4.0·exp(−X1) term is a strongly nonlinear exponential decay: at X1 = 0 it contributes 4.0; at X1 = 3 it contributes only 0.20; at X1 = 5 it is negligible (0.027). The linear β(X1) will be strongly negative, correctly signaling that increasing X1 reduces Y1.

The minimization purpose (`< 10`) uses score = (threshold − μ) + κ·σ, so the optimizer seeks low-Y1 candidates. Minimum Y1 is achieved at X1 = 10 (making exp(−X1) ≈ 0), X2 = 0 (no X2 contribution), and X3 = A (zero categorical bonus) — all at the boundary of the design space, hence **interpolation** (corners are explicitly included in the candidate grid).

The categorical kernel `K_cat` handles the three levels via delta kernels. Even if some level combinations are sparse in training, the model can interpolate between levels.

**Verdict: ✓ Match** — Optimizer correctly recommends X1 = 10, X2 = 0, X3 = A

---

### Sample 6 — Four Variables with Explicit Interaction (Derived)

**Data** — 10 training observations. Four continuous variables X1–X4 ∈ [0, 10], integer step 1. A **Derived sheet** provides X1·X2 as an explicit interaction column. Variables span their full ranges.

<details>
<summary>Training data (click to expand)</summary>

*(Data stored in Sample6.xlsx. True model: Y1 = 1.2·X1 + X2 − 0.8·(X1·X2) + 0.7·X3 + 0.5·X4. Approximate ranges: all Xi ∈ [1, 9].)*

</details>

**Model** — `Y1 = 1.2·X1 + 1.0·X2 − 0.8·(X1·X2) + 0.7·X3 + 0.5·X4`

**Purpose** — Maximize (`>`)

**Analysis** — With X1·X2 provided in the Derived sheet, the model partitions the interaction cleanly: the fitted coefficient β(X1·X2) ≈ −0.83 closely matches the true −0.8. The marginal effect of X1 becomes positive when X2 is low (1.2 − 0.8·X2 > 0 when X2 < 1.5), so the optimal strategy is X1 = 10 (high) and X2 = 0 (low), producing Y1 = 12 − 0 + 7 + 5 = 24.

The corner X1 = 10, X2 = 0 is a boundary point in the candidate grid. For X3 and X4, the maximum at 10 is also a boundary — all four are **boundary/extrapolation** candidates. The corner is explicitly included in the LHS + corner candidate set, ensuring it appears in the candidate table.

**Verdict: ✓ Match** — Optimizer correctly recommends X1 = 10, X2 = 0, X3 = 10, X4 = 10 (Y1 = 24)

---

### Sample 7 — Two Outputs with Opposing Optima

**Data** — 10 training observations. Four continuous variables X1–X4 ∈ [0, 10], integer step 1. Two output variables Y1 and Y2 with opposing coefficient structures.

<details>
<summary>Training data (click to expand)</summary>

*(Data stored in Sample7.xlsx. True models: Y1 = 2.0·X1 − 1.2·X2 + … , Y2 = −2.0·X1 + 1.2·X2 + … + 20. Variable ranges: all Xi ∈ [1, 9].)*

</details>

**Model** — `Y1 = 2.0·X1 − 1.2·X2 + minor terms`, `Y2 = −2.0·X1 + 1.2·X2 + minor terms + 20`

**Purpose** — Maximize both Y1 and Y2 (`>`)

**Analysis** — This is a classic trade-off: maximizing Y1 (high X1, low X2) directly conflicts with maximizing Y2 (low X1, high X2). The fitted coefficients closely recover the true structure — Y1: β(X1) ≈ +2.05, β(X2) ≈ −1.14; Y2: β(X1) ≈ −2.07, β(X2) ≈ +1.21. Both outputs achieve R² = 1.000.

The multi-output scope structure produces:
- `Optimize Y1`: recommends X1 = 10, X2 = 0 — a **boundary** point (corner)
- `Optimize Y2`: recommends X1 = 0, X2 = 10 — the opposite corner
- `Optimize All`: geometric-mean desirability finds a **compromise** (e.g., X1 ≈ 5, X2 ≈ 5)

Both boundary recommendations are corners explicitly included in the candidate grid — pure **extrapolation** beyond typical training data range.

**Verdict: ✓ Match** — Per-Y optima correctly identified; Optimize All surfaces a trade-off compromise

---

### Sample 8 — Strong Interaction, 5 Variables (Derived)

**Data** — 20 training observations. Five continuous variables X1–X5 ∈ [0, 10], integer step 1. A **Derived sheet** provides X1·X2. The larger training set (20 vs. 10) provides better coverage of a 5-dimensional space.

<details>
<summary>Training data (click to expand)</summary>

*(Data stored in Sample8.xlsx. True model: Y1 = 2.0·X1 + 1.4·X2 − 3.0·(X1·X2) + 0.6·X3 + 0.4·X4 + 0.5·X5. Variable ranges: all Xi ∈ [0, 10], integer steps.)*

</details>

**Model** — `Y1 = 2.0·X1 + 1.4·X2 − 3.0·(X1·X2) + 0.6·X3 + 0.4·X4 + 0.5·X5`

**Purpose** — Maximize (`>`)

**Analysis** — The −3.0·(X1·X2) term is a strong, destructive interaction. Without the Derived column, the model would absorb it into deeply negative β(X1) and β(X2), making the entire X1–X2 plane look bad. With the Derived column, the model recovers β(X1) ≈ +2.4, β(X2) ≈ +0.6, β(X1·X2) ≈ −2.6 — correctly partitioned. The optimal strategy mirrors Sample 6: maximize X1 while minimizing X2, maximizing all others.

All optimal values (X1 = 10, X2 = 0, X3 = X4 = X5 = 10) are at the boundary of the design space. The candidate set explicitly includes this corner, so this is a **boundary/interpolation** problem in the sense that the corner is always evaluated.

**Verdict: ✓ Match** — Optimizer correctly recommends X1 = 10, X2 = 0, X3 = X4 = X5 = 10 (Y1 = 35)

---

### Sample 9 — Counter-Intuitive Optimum via Dominant Interaction

**Data** — 10 training observations. Three continuous variables X1–X3 ∈ [0, 10] and one categorical variable X4 ∈ {A, B, C}. Training X1 spans [3.80, 8.00], X2 spans [1.82, 7.91], X3 spans [1.93, 7.10]. Category C appears in only 2 of 10 training rows; the majority are category A.

<details>
<summary>Training data (click to expand)</summary>

| id | X1 | X2 | X3 | X4 | Y1 |
|---|---|---|---|---|---|
| 1 | 7.70 | 2.97 | 2.13 | C | 7.77 |
| 2 | 5.79 | 3.91 | 6.04 | A | 13.67 |
| 3 | 7.30 | 1.82 | 7.10 | A | 6.74 |
| 4 | 3.99 | 7.91 | 1.93 | A | 1.25 |
| 5 | 7.02 | 3.55 | 2.85 | A | 6.31 |
| 6 | 6.54 | 2.52 | 3.33 | C | 9.27 |
| 7 | 7.87 | 7.39 | 4.53 | A | 21.11 |
| 8 | 4.18 | 5.23 | 4.98 | A | 14.46 |
| 9 | 3.80 | 7.64 | 4.26 | A | 17.33 |
| 10 | 8.00 | 5.49 | 5.88 | A | 22.04 |

</details>

**Model** — `Y1 = 0.8·X1 − 2.0·X2 − 1.5·X3 + 1.1·(X2·X3) + cat(A=0, B=2, C=4)`

**Purpose** — Maximize (`>`)

**Analysis** — The individual coefficients of X2 (−2.0) and X3 (−1.5) suggest both should be minimized. This is the trap. The interaction term 1.1·(X2·X3) grows to 1.1 × 100 = 110 when X2 = X3 = 10, far outweighing the individual penalties of −20 and −15. The true global maximum is **Y1 = 87** at X1 = X2 = X3 = 10, X4 = C.

The training Y1 values top out at 22 — the optimizer must extrapolate to a response 4× larger than anything in training. X1 = 10 is beyond the training max (8.00). X2 = 10 and X3 = 10 are both beyond training ranges. Category C appears only twice in training. This is a heavy-duty **extrapolation** in every dimension simultaneously.

Despite this, the model handles it: the fitted β(X2) ≈ +2.04 and β(X3) ≈ +2.19 are both *positive* (not negative, as in the true model's individual terms). This is not a sign reversal error — it correctly captures the **average marginal effect** of X2, which is −2.0 + 1.1·E[X3] ≈ −2.0 + 4.7 = +2.7 over the training distribution. With high R² (≈ 0.999), the optimizer correctly identifies X1 = X2 = X3 = 10, X4 = C as the optimum.

**Key lesson**: A positive fitted β for a variable with a negative individual coefficient in the true model is not a model failure — it correctly encodes the interaction-driven marginal effect.

**Verdict: ✓ Match** — Optimizer correctly recommends X1 = X2 = X3 = 10, X4 = C (Y1 = 87)

---

### Sample 10 — Exponential Dominance, 6 Variables

**Data** — 20 training observations. Six continuous variables X1–X6 ∈ [0, 10], integer step 1. The larger training set provides better coverage for the 6-dimensional space. X5 values span from near 0 to near 10.

<details>
<summary>Training data (click to expand)</summary>

*(Data stored in Sample10.xlsx. True model: Y1 = 0.7·X1 + 0.5·X2 + 0.6·X3 + 0.4·X4 + 100·exp(−X5) + 0.4·X6. Variable ranges: all Xi ∈ [0, 10], integer steps.)*

</details>

**Model** — `Y1 = 0.7·X1 + 0.5·X2 + 0.6·X3 + 0.4·X4 + 100·exp(−X5) + 0.4·X6`

**Purpose** — Maximize (`>`)

**Analysis** — The 100·exp(−X5) term spans an enormous range: 100 at X5 = 0, declining to virtually 0 by X5 = 5. The other six variables contribute at most 0.4–0.7 per unit — a combined maximum of ~37 — whereas the exponential term alone contributes 100 at its peak. The global maximum Y1 ≈ 126 is achieved at X5 = 0 with all others at their maxima.

The linear β(X5) ≈ −0.47 captures the *directional* signal (decrease X5) but massively understates the true effect (−100 vs. a range of 0.4–0.7 for other coefficients). The GP absorbs the nonlinearity, and with n = 20 observations covering the full X5 range, the GP accurately learns the steep exponential shape.

At X5 = 0, this is a **boundary** point (corner), explicitly included in the candidate grid. The algorithm evaluates it and predicts Y1 ≈ 126. The optimization correctly identifies it as the global candidate.

**Key lesson**: When a nonlinear function dominates, the linear β gives only directional information. The GP does the heavy lifting — as long as training data covers the variable's full range.

**Verdict: ✓ Match** — Optimizer correctly recommends X5 = 0, all others = 10 (Y1 ≈ 126)

---

## 5. Summary

| Sample | Inputs | True Model Type | Purpose | Optimum | Extrapolation? | Verdict |
|--------|--------|----------------|---------|---------|----------------|---------|
| 1 | X1 | Linear | `>` | X1=10 | Mild (boundary) | ✓ |
| 2 | X1, X2 | Quadratic (X1²) | `>` | X1=9, X2=10 | Full (beyond training range) | ✓ (2nd iter.) |
| 3 | X1, X2 | Interaction, unmodeled | `>` | X1=10, X2=0 | Full (extrapolated response) | ✓ |
| 4 | X1, X2, X3 | Sinusoidal | `=5` | Near X1=π/2, X2,X3 high | Partial | ~ |
| 5 | X1, X2, X3(cat) | Exponential + categorical | `<10` | X1=10, X2=0, X3=A | Boundary (corner) | ✓ |
| 6 | X1–X4 + derived X1·X2 | Interaction (Derived) | `>` | X1=10, X2=0, X3=X4=10 | Boundary | ✓ |
| 7 | X1–X4, Y1+Y2 | Linear trade-off | `>` | Y1: X1=10,X2=0 / Y2: X1=0,X2=10 | Boundary (corners) | ✓ |
| 8 | X1–X5 + derived X1·X2 | Strong interaction (Derived) | `>` | X1=10, X2=0, others=10 | Boundary | ✓ |
| 9 | X1–X3, X4(cat) | Interaction, counter-intuitive | `>` | X1=X2=X3=10, X4=C | Full | ✓ |
| 10 | X1–X6 | Exponential (large scale) | `>` | X5=0, others=10 | Boundary | ✓ |

**Result: 9 ✓ Match, 1 ~ Partial, 0 ✗ Mismatch**

The one remaining partial case (Sample 4) involves a periodic sin(X1) function where the target value `= 5` can be achieved by multiple X1 branches, and sparse 3-variable data makes it difficult to pin down the exact branch. Sample 2, which initially appeared partial (the first-round recommendation was X1 = 20 due to linear extrapolation), resolved correctly in the second round once real data at X1 = 20 was added — the large residual triggered automatic selection of X1² and the optimizer found the true interior optimum X1 = 9.

---

## 6. Design Principles Revealed by Verification

**Use the Derived sheet for known interactions.** Samples 6 and 8 show that explicit interaction columns produce correct β signs and accurate optimization, whereas leaving the interaction unmodeled (Sample 3) causes sign reversal in β — even though the GP still finds the right recommendation. The Derived sheet approach is both more interpretable and more robust.

**Train where the optimum might be — and let surprising results guide the next run.** Sample 2 illustrates how iterative experimentation corrects linear-extrapolation errors. The first suggestion (X1 = 20) produced an unexpectedly low result (Y1 = 12.5 vs. predicted ≈ 60), generating a large residual that triggered automatic selection of X1² in the next run — and the optimizer then correctly identified X1 = 9. Deliberately evaluating the model's top recommendation, even if it seems wrong, provides the residual signal needed to self-correct.

**Counter-intuitive optima are real and detectable.** Sample 9 demonstrates that a variable's linear β can be positive even when its individual coefficient in the true model is negative, provided a dominant interaction drives the average marginal effect positive. The optimizer correctly finds these counter-intuitive maxima when R² is high.

**Nonlinearity scale doesn't matter — range coverage does.** Sample 10's 100·exp(−X5) term spans two orders of magnitude but is perfectly handled because the training data covers the full X5 range. In Sample 2, the model needed one data point at the extrapolation boundary (X1 = 20) to expose the quadratic decline and trigger automatic curvature detection — the iterative Optimize → Evaluate → Re-optimize workflow did exactly that.

**Auto 2nd-order terms activate when residual signal is strong enough.** The automatic selection of X1² requires |cor(X1², residuals)| ≥ 0.30. With only training data in X1 ∈ [2, 7], the correlation falls below threshold. But after a single evaluation at X1 = 20 produces a huge negative residual (X1² = 400 is a far outlier), the correlation spikes well above 0.30 and X1² is selected automatically — no manual Derived sheet edit required.

---

> Analyses are based on a Python reproduction of the semi-parametric Bayes algorithm described in REPRODUCTION_PROMPT.md. Exact numerical values may differ slightly from the AutoXP3 R implementation. If any discrepancy with official documentation is found, the official source takes precedence.
