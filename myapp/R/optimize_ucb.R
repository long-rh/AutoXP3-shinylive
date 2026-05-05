# ============================================================
# UCB Optimization utilities
# ============================================================

# ============================================================
# Threshold-aware acquisition
# purpose: ">2", ">=2", "<5", "<=5"
# score: (mean shift from threshold) + kappa * sd
#   - for ">" : (mu - thr) + kappa*sd
#   - for "<" : (thr - mu) + kappa*sd
# Notes:
# - This keeps the same "UCB style" while respecting the threshold.
# ============================================================
ucb_score <- function(mu, sd, purpose, kappa = 2.0, parse_fun = parse_purpose) {
  
  pp <- parse_fun(purpose)
  
  mu <- as.numeric(mu)
  sd <- as.numeric(sd)
  sd <- pmax(sd, 1e-12)  # avoid zero
  
  # "=" target: get as close as possible to the target value
  if (!is.null(pp$type) && pp$type == "target") {
    target <- if (is.na(pp$value)) 0 else pp$value
    return(-abs(mu - target) + kappa * sd)
  }
  
  # default: maximize mu
  if (pp$type != "bound") {
    return(mu + kappa * sd)
  }
  
  thr <- if (is.na(pp$value)) 0 else pp$value
  
  if (pp$op %in% c(">", ">=")) {
    return((mu - thr) + kappa * sd)
  }
  
  if (pp$op %in% c("<", "<=")) {
    return((thr - mu) + kappa * sd)
  }
  
  mu + kappa * sd
}