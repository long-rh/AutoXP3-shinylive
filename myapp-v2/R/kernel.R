# ---------- Linear algebra helper: solve V x = b via Cholesky ----------
chol_solve <- function(L, b) {
  # Given V = L %*% t(L) with L lower-triangular (from chol(..., pivot=FALSE)),
  # solve V x = b
  y <- forwardsolve(L, b, upper.tri = FALSE, transpose = FALSE)
  x <- backsolve(t(L), y, upper.tri = TRUE, transpose = FALSE)
  x
}

# ---------- For each matrix component ---------------------------------------------
kernel <- function(xi, xj, type = c("rbf", "linear", "quad", "rbf_linear"),
                   theta1 = 1, theta2 = 0.4) {
  type <- match.arg(type)
  switch(type,
         rbf = {
           d2 <- sum((xi - xj)^2)
           return(theta1 * exp(-0.5*d2 / theta2))
         },
         
         linear = {
           return(sum(xi*xj) + 1)
         },
         
         quad = {
           return((sum(xi*xj) + 1)^2)
         },
         rbf_linear = {
           d2 <- sum((xi - xj)^2)
           return(theta1 * exp(-0.5*d2 / theta2) + sum(xi*xj) + 1)
         }
  )
}


# ---------- Matrix build ---------------------------------------------
kernel_matrix <- function(X1, X2 = X1,
                          type = "rbf",
                          theta1 = 1,
                          theta2 = 1,
                          noise = 0,
                          jitter = 1e-5) {
  X1 <- as.matrix(X1)
  X2 <- as.matrix(X2)
  N1 <- nrow(X1)
  N2 <- nrow(X2)
  K <- matrix(0, nrow = N1, ncol = N2)
  
  for (i in 1:N1) {
    xi <- X1[i, , drop = FALSE]
    for (j in 1:N2) {
      xj <- X2[j, , drop = FALSE]
      K[i, j] <- kernel(xi, xj,
                        type = type,
                        theta1 = theta1,
                        theta2 = theta2)
    }
  }
  # noise for only diagonal component
  if (noise != 0 && identical(X1, X2)) {
    K <- K + noise * diag(N1)
  }
  return(K)
}

#GPに算
GP_pred <- function(X_train, Y_train, X_pred, 
                    theta1 = 1, theta2 = 1,
                    theta3 = 0, #noise
                    type = c("rbf", "linear", "quad", "rbf_linear")
                    ){
                    #check input
                    X_train <- as.matrix(X_train)
                    Y_train <- as.matrix(Y_train)
                    X_pred <- as.matrix(X_pred)
                    N <- nrow(X_train)
                    M <- nrow(X_pred)
                    if (N != length(Y_train)){
                      stop("length(x_train) must equal length(y_train)")
                    }
                    # learning K(N×N) with noise
                    K <- kernel_matrix(X_train, X_train,
                                       type = type,
                                       theta1 = theta1, theta2 = theta2,
                                       noise = theta3)
                    
                    # prediction k(N×M): without noise
                    k <- kernel_matrix(X_train, X_pred,
                                       type = type,
                                       theta1 = theta1, theta2 = theta2)
                    
                    # prediction s(M×M)
                    s <- kernel_matrix(X_pred, X_pred,
                                       type = type,
                                       theta1 = theta1, theta2 = theta2)
                    
                    # Cholesky: V = L L^T
                    L <- chol(K)  # upper-tri by default in R: chol(V) returns U s.t. t(U)U = V
                    # We'll convert to lower-tri for forwardsolve/backsolve style:
                    # If U is upper, then V = t(U)U => let L = t(U)
                    L <- t(L)
                    
                    yy <- chol_solve(L, Y_train)#K*yy = y_train, solve yy
                    v  <- chol_solve(L, k)#Kv=k, solve v
                    mu <- t(k)%*%yy#mean
                    var_f <- s - t(k) %*% v #fuction variance var_f(M×M)
                    if (abs(theta3) > .Machine$double.eps^0.5) {
                      var_y <- var_f + theta3 * diag(M) #observation variance var_y
                      return(list(mu = mu, var_f = var_f, var_y = var_y))
                    } else {
                      return(list(mu = mu, var_f = var_f))
                    }
}