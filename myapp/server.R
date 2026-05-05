library(shiny)
library(readxl)
if (!requireNamespace("writexl", quietly = TRUE))
  install.packages("writexl", repos = "https://cloud.r-project.org")
library(writexl)

`%||%` <- function(a, b) if (!is.null(a)) a else b

source("R/utils.R")
source("R/kernel.R")
source("R/categorical-kernel.R")
source("R/standardize.R")
source("R/semiparam_bayes.R")
source("R/optimize_ucb.R")
source("R/excel_validation.R")

shinyServer(function(input, output, session) {

  rv <- reactiveValues(
    def          = NULL,
    data         = NULL,
    X_names      = NULL,
    Y_names      = NULL,
    X_cont       = NULL,
    X_cat        = NULL,
    fits         = list(),    # 全Y分のfit（名前付きリスト）
    y_view       = NULL,      # Model/Analyzeタブで表示中のY
    fit          = NULL,      # rv$fits[[rv$y_view]] のエイリアス
    cand         = NULL,
    plot_df      = NULL,
    plot_meta    = NULL,
    error_msg    = NULL,
    derived_cols     = character(0),
    derived_formulas = list(),
    constraints      = character(0),
    model_params     = list(), # Modelシートから読み込んだパラメータ
    model_sheet_df   = NULL,
    optimize_status_msg = NULL,
    upload_path      = NULL,   # アップロードされたExcelの一時パス
    upload_name      = NULL,    # 元のファイル名
    upload_valid    = FALSE,
    last_fit_hp2 = NULL,
    last_fit_hp3 = NULL,
    #last_fit_use_yj = NULL,
    #last_fit_yj_lambda = NULL
  )

  fail <- function(msg) {
    rv$error_msg <- msg
    rv$upload_valid <- FALSE
    return(NULL)
  }

  output$ui_error <- renderUI({
    if (is.null(rv$error_msg) || rv$error_msg == "") return(NULL)
    div(
      style = "background:#3b1218;border:1px solid #a33;color:#ffd6d6;padding:10px;border-radius:8px;margin-top:8px;font-size:13px;",
      strong("Error: "), span(rv$error_msg)
    )
  })

  # ══════════════════════════════════════════════════════════
  # Excel 読み込み
  # ══════════════════════════════════════════════════════════
  observeEvent(input$file_xlsx, {
    req(input$file_xlsx)
    rv$error_msg <- NULL
    path <- input$file_xlsx$datapath
    rv$upload_path <- path
    rv$upload_name <- input$file_xlsx$name

    upload_check <- validate_excel_upload(path, normalize_sheet_name = normalize_sheet_name)
    if (!is.null(upload_check$error)) return(fail(upload_check$error))

    sheets   <- upload_check$sheets
    ns       <- upload_check$normalized_sheets
    i_def    <- upload_check$i_def
    i_data   <- upload_check$i_data
    def_raw  <- upload_check$def_raw
    data_raw <- upload_check$data_raw

    def <- as.data.frame(def_raw)
    dat <- as.data.frame(data_raw)

    required_cols <- c("Parameter", "Min", "Standard", "Max", "Type", "Interval", "Purpose")
    if (!all(required_cols %in% names(def))) {
      return(fail("Definition sheet must contain columns: Parameter, Min, Standard, Max, Type, Interval, Purpose"))
    }

    def2 <- data.frame(
      Parameter    = as.character(def$Parameter),
      Type         = as.character(def$Type),
      Interval     = suppressWarnings(as.numeric(def$Interval)),
      Purpose      = as.character(def$Purpose),
      Min_raw      = as.character(def$Min),
      Standard_raw = as.character(def$Standard),
      Max_raw      = as.character(def$Max),
      stringsAsFactors = FALSE
    )
    def2 <- def2[!is.na(def2$Parameter) & trimws(def2$Parameter) != "", , drop = FALSE]

    is_cont <- tolower(def2$Type) == "continuous"
    def2$min_num      <- NA_real_
    def2$standard_num <- NA_real_
    def2$max_num      <- NA_real_
    def2$min_num[is_cont]      <- suppressWarnings(as.numeric(def2$Min_raw[is_cont]))
    def2$standard_num[is_cont] <- suppressWarnings(as.numeric(def2$Standard_raw[is_cont]))
    def2$max_num[is_cont]      <- suppressWarnings(as.numeric(def2$Max_raw[is_cont]))

    X_names <- def2$Parameter[grepl("^X", def2$Parameter, ignore.case = TRUE)]
    Y_names <- def2$Parameter[grepl("^Y", def2$Parameter, ignore.case = TRUE)]

    if (length(X_names) < 1) return(fail("Definition must contain at least one X parameter (e.g., X1)."))
    if (length(Y_names) < 1) return(fail("Definition must contain at least one Y parameter (e.g., Y1)."))
    if (!("id" %in% names(dat))) return(fail("Data sheet must contain column 'id'."))
    if (!all(X_names %in% names(dat))) return(fail("Data sheet must contain all X columns defined in Definition."))
    if (!all(Y_names %in% names(dat))) return(fail("Data sheet must contain all Y columns defined in Definition."))

    X_cont <- def2$Parameter[tolower(def2$Type) == "continuous"  & grepl("^X", def2$Parameter, ignore.case=TRUE)]
    X_cat  <- def2$Parameter[tolower(def2$Type) == "categorical" & grepl("^X", def2$Parameter, ignore.case=TRUE)]

    # Feature 2: 派生変数検出（DataにあってDefinitionのX/Y/idにない数値列）
    base_cols    <- c("id", X_names, Y_names)
    extra_cols   <- setdiff(names(dat), base_cols)
    derived_cols <- extra_cols[vapply(extra_cols, function(nm) {
      v <- suppressWarnings(as.numeric(dat[[nm]]))
      sum(!is.na(v)) > 0
    }, logical(1))]

    dat2 <- dat[, c("id", X_names, Y_names, derived_cols), drop = FALSE]
    dat2 <- na.omit(dat2)
    dat2$id <- as.character(dat2$id)
    for (nm in c(X_cont, Y_names, derived_cols)) dat2[[nm]] <- as.numeric(dat2[[nm]])
    for (nm in X_cat) dat2[[nm]] <- as.character(dat2[[nm]])

    # Feature 3: Constraints シート読み込み
    i_con <- which(ns %in% c("constraints", "constraint"))
    constraints <- character(0)
    if (length(i_con) >= 1) {
      con_raw <- tryCatch(
        as.data.frame(read_excel(path, sheet = sheets[i_con[1]])),
        error = function(e) NULL
      )
      if (!is.null(con_raw) && ncol(con_raw) >= 1) {
        constraints <- as.character(con_raw[[1]])
        constraints <- constraints[!is.na(constraints) & trimws(constraints) != ""]
        # keep only lines that look like constraints (must contain < or >)
        constraints <- constraints[grepl("[<>]", constraints)]
      }
    }

    # Model シート読み込み（RBF パラメータ + β 事前分布）
    i_mod <- which(ns %in% c("model"))
    model_params <- list(
      ell = NULL,
      sigma2 = NULL,
      mu0_map = list(),
      sig0_map = list()
    )
    rv$model_sheet_df <- NULL
    
    if (length(i_mod) >= 1) {
      mod_raw <- tryCatch(
        as.data.frame(read_excel(path, sheet = sheets[i_mod[1]])),
        error = function(e) NULL
      )
      
      if (!is.null(mod_raw)) {
        # 表示用は元の列だけ保持
        rv$model_sheet_df <- mod_raw
      }
      
      if (!is.null(mod_raw) && ncol(mod_raw) >= 3) {
        # ここから下は内部処理用
        mod2 <- mod_raw
        
        nc <- tolower(trimws(names(mod2)))
        i_target <- which(nc %in% c("target y", "target_y", "targety"))[1]
        i_type   <- which(nc == "type")[1]
        i_param  <- which(nc == "parameter")[1]
        i_val    <- which(nc == "value")[1]
        
        if (!is.na(i_type) && !is.na(i_param) && !is.na(i_val)) {
          mod2$..type..   <- tolower(trimws(as.character(mod2[[i_type]])))
          mod2$..target.. <- if (!is.na(i_target)) trimws(as.character(mod2[[i_target]])) else "All"
          mod2$..param..  <- trimws(as.character(mod2[[i_param]]))
          mod2$..val..    <- suppressWarnings(as.numeric(mod2[[i_val]]))
          
          mod2$..target..[is.na(mod2$..target..) | mod2$..target.. == ""] <- "All"
          mod2 <- mod2[!is.na(mod2$..val..), , drop = FALSE]
          
          for (k in seq_len(nrow(mod2))) {
            typ <- mod2$..type..[k]
            tgt <- mod2$..target..[k]
            pnm <- mod2$..param..[k]
            pv  <- mod2$..val..[k]
            
            if (typ == "rbf") {
              if ((pnm == "theta2" || pnm == "ell") && is.finite(pv) && pv > 0) {
                model_params$ell <- pv
              }
              if (pnm == "sigma2" && is.finite(pv) && pv >= 0) {
                model_params$sigma2 <- pv
              }
            }
            
            if (typ == "prior") {
              if (is.null(model_params$mu0_map[[tgt]]))  model_params$mu0_map[[tgt]]  <- list()
              if (is.null(model_params$sig0_map[[tgt]])) model_params$sig0_map[[tgt]] <- list()
              
              if (endsWith(pnm, "_mu")) {
                model_params$mu0_map[[tgt]][[sub("_mu$", "", pnm)]] <- pv
              }
              if (endsWith(pnm, "_var")) {
                model_params$sig0_map[[tgt]][[sub("_var$", "", pnm)]] <- pv
              }
            }
          }
        }
      }
    }
    
    rv$model_params <- model_params
    
    output$ui_model_sheet_card <- renderUI({
      req(rv$data)
      
      if (is.null(rv$model_sheet_df) || nrow(rv$model_sheet_df) == 0) {
        return(
          div(class = "cardx",
              div(class = "box-title", "Model sheet"),
              div(class = "note", "No model sheet loaded.")
          )
        )
      }
      
      div(class = "cardx",
          div(class = "box-title", "Model Settings"),
          tableOutput("tbl_model_sheet")
      )
    })
    
    output$tbl_model_sheet <- renderTable({
      req(rv$model_sheet_df)
      rv$model_sheet_df
    }, striped = FALSE, bordered = TRUE, hover = TRUE)
    
    
    output$ui_constraints_card <- renderUI({
      req(rv$data)
      
      txt <- if (length(rv$constraints) > 0) rv$constraints else "none"
      
      div(class = "cardx",
          div(class = "box-title", "Constraints"),
          if (length(rv$constraints) > 0) {
            tags$ul(
              style = "margin-bottom:0;",
              lapply(rv$constraints, function(x) tags$li(x))
            )
          } else {
            div(class = "note", "No constraints loaded.")
          }
      )
    })

    # RBF パラメータが Model シートにあれば UI を更新
    if (!is.null(model_params$ell))    updateNumericInput(session, "hp2", value = model_params$ell)
    if (!is.null(model_params$sigma2)) updateNumericInput(session, "hp3", value = model_params$sigma2)

    # Feature 2: 派生変数の列名から式を自動検出
    # 対応パターン: X, X*X, X*X'(交互作用), 1/X, exp(X), exp(-X), log(X)
    detect_formula_from_name <- function(col_name, x_vars) {
      if (length(x_vars) == 0) return(NULL)
      xp <- paste0("(", paste(x_vars, collapse = "|"), ")")
      patterns <- c(
        paste0("^", xp, "$"),
        paste0("^", xp, "\\s*\\*\\s*", xp, "$"),
        paste0("^1\\s*/\\s*", xp, "$"),
        paste0("^exp\\(", xp, "\\)$"),
        paste0("^exp\\(-", xp, "\\)$"),
        paste0("^log\\(", xp, "\\)$"),
        paste0("^log10\\(", xp, "\\)$"),
        paste0("^sqrt\\(", xp, "\\)$"),
        paste0("^sin\\(", xp, "\\)$"),
        paste0("^cos\\(", xp, "\\)$")
      )
      if (any(sapply(patterns, function(p) grepl(p, trimws(col_name))))) {
        return(trimws(col_name))   # 列名がそのまま R 式として使える
      }
      NULL
    }

    derived_formulas <- list()
    for (col in derived_cols) {
      f <- detect_formula_from_name(col, X_cont)
      if (!is.null(f)) derived_formulas[[col]] <- f
    }

    rv$def              <- def2
    rv$data             <- dat2
    rv$X_cont           <- X_cont
    rv$X_cat            <- X_cat
    rv$X_names          <- X_names
    rv$Y_names          <- Y_names
    rv$derived_cols     <- derived_cols
    rv$derived_formulas <- derived_formulas
    rv$constraints      <- constraints
    rv$model_params     <- model_params
    rv$fits             <- list()
    rv$fit              <- NULL
    rv$y_view           <- if ("Y1" %in% Y_names) "Y1" else Y_names[1]
    rv$cand             <- NULL
    rv$optimize_status_msg <- "No optimize results with the current models. Please run Suggest next experiments."
    # upload直後に全Yを自動fit
    for (yn in rv$Y_names) {
      ok <- tryCatch({ do_fit_one(yn); TRUE }, error = function(e) { rv$error_msg <- conditionMessage(e); FALSE })
      if (!ok) return(NULL)
    }
    rv$upload_valid <- TRUE
    rv$fit <- rv$fits[[rv$y_view]]
    rv$last_fit_hp2       <- input$hp2
    rv$last_fit_hp3       <- input$hp3
    #rv$last_fit_use_yj    <- isTRUE(input$use_yeojohnson)
    #rv$last_fit_yj_lambda <- if (isTRUE(input$use_yeojohnson)) input$yj_lambda else NA_real_
  })

  output$ui_sheet     <- renderUI({ NULL })
  output$ui_col_select <- renderUI({ NULL })

  # ══════════════════════════════════════════════════════════
  # Y ビューセレクター（Model/Analyzeタブの表示切替）
  # ══════════════════════════════════════════════════════════
  output$ui_y_view <- renderUI({
    req(rv$Y_names)
    if (length(rv$Y_names) <= 1) return(NULL)
    div(
      style = "margin-top:8px;",
      selectInput("y_view_sel", "View Y",
                  choices  = rv$Y_names,
                  selected = rv$y_view %||% rv$Y_names[1])
    )
  })

  observeEvent(input$y_view_sel, {
    rv$y_view <- input$y_view_sel
    if (!is.null(rv$fits[[rv$y_view]])) rv$fit <- rv$fits[[rv$y_view]]
  })
  
  # save report
  output$ui_btn_save_result <- renderUI({
    ready <- isTRUE(tryCatch(report_ready_reactive(), error = function(e) FALSE))
    
    if (ready) {
      downloadButton("download_model", "Save Result", class = "btn-wide btn-primary")
    } else {
      tags$button(
        "Save Result",
        class = "btn btn-default btn-wide",
        style = "background-color:#d9d9d9; color:#888; border-color:#d0d0d0; cursor:not-allowed;",
        disabled = NA
      )
    }
  })

  # ══════════════════════════════════════════════════════════
  # Y 変換カード（Data タブ）— Yeo-Johnson
  # ══════════════════════════════════════════════════════════
  # output$ui_boxcox_card <- renderUI({
  #   req(rv$data)
  #   div(class = "cardx",
  #     div(class = "box-title", "Y Transformation (Yeo-Johnson)"),
  #     checkboxInput("use_yeojohnson", "Apply Yeo-Johnson transformation", value = FALSE),
  #     conditionalPanel(
  #       condition = "input.use_yeojohnson == true",
  #       numericInput("yj_lambda", HTML("&lambda;"), value = 0.0, step = 0.1)
  #     ),
  #     div(class = "note",
  #         HTML("&lambda; = 1: identity &nbsp;|&nbsp; &lambda; = 0: log-like &nbsp;|&nbsp;
  #              &lambda; = 2: negated log-like for negative Y.<br>
  #              Works for any real Y (no sign requirement)."))
  #   )
  # })

  # ══════════════════════════════════════════════════════════
  # Input / Output info
  # ══════════════════════════════════════════════════════════
  output$ui_info <- renderUI({
    req(rv$def, rv$X_names, rv$Y_names)
    x_cont_txt <- paste(rv$X_cont, collapse = ", ")
    x_cat_txt  <- paste(rv$X_cat,  collapse = ", ")
    drv_txt    <- if (length(rv$derived_cols) > 0) paste(rv$derived_cols, collapse = ", ") else "none"

    # 全Yのpurposeを列挙
    y_purpose_lines <- lapply(rv$Y_names, function(yn) {
      row  <- rv$def[rv$def$Parameter == yn, , drop = FALSE]
      purp <- if (nrow(row) > 0 && !is.na(row$Purpose[1]) && trimws(row$Purpose[1]) != "NA")
                row$Purpose[1] else "—"
      tags$div(paste0("  ", yn, ": ", purp))
    })

    div(
      tags$div("Input parameter:"),
      tags$div(paste0("Continuous: ", x_cont_txt)),
      tags$div(paste0("Categorical: ", if (nchar(x_cat_txt) > 0) x_cat_txt else "none")),
      tags$div(paste0("Derived: ", drv_txt)),
      tags$br(),
      tags$div("Output (Y) / Purpose:"),
      do.call(tagList, y_purpose_lines)
    )
  })

  # ══════════════════════════════════════════════════════════
  # 1. Data タブ表示
  # ══════════════════════════════════════════════════════════
  output$tbl_uploaded_data <- renderTable({
    req(rv$data)
    rv$data
  }, striped = FALSE, bordered = TRUE, hover = TRUE)

  output$tbl_definition <- renderTable({
    req(rv$def)
    df <- rv$def[c("Parameter", "Min_raw", "Standard_raw", "Max_raw", "Type", "Interval", "Purpose")]
    colnames(df) <- c("Parameter", "Min", "Standard", "Max", "Type", "Interval", "Purpose")
    df
  }, striped = FALSE, bordered = TRUE, hover = TRUE)

  # ══════════════════════════════════════════════════════════
  # Fit model
  # ══════════════════════════════════════════════════════════
  clamp_nonneg <- function(id, default = 0) {
    observeEvent(input[[id]], {
      val <- input[[id]]
      if (is.null(val) || !is.finite(val) || val <= 0)
        updateNumericInput(session, id, value = default)
    })
  }
  clamp_nonneg("hp2", 1e-6)
  clamp_nonneg("hp3", 1e-6)
  
  model_dirty_reactive <- reactive({
    req(!is.null(rv$last_fit_hp2), !is.null(rv$last_fit_hp3))
    
    # cur_use_yj <- isTRUE(input$use_yeojohnson)
    # cur_yj_lam <- if (cur_use_yj) input$yj_lambda else NA_real_
    
    !isTRUE(all.equal(input$hp2, rv$last_fit_hp2)) ||
      !isTRUE(all.equal(input$hp3, rv$last_fit_hp3))
      # || !identical(cur_use_yj, rv$last_fit_use_yj) ||
      # || !isTRUE(all.equal(cur_yj_lam, rv$last_fit_yj_lambda))
  })
  
  report_ready_reactive <- reactive({
    req(rv$Y_names)
    
    # 全Yがfit済みか
    fit_ok <- length(rv$fits) == length(rv$Y_names) &&
      all(rv$Y_names %in% names(rv$fits))
    
    # エラーが出ていないか
    err_ok <- is.null(rv$error_msg) || rv$error_msg == ""
    
    fit_ok && err_ok
  })

  do_fit_one <- function(y_name) {
    req(rv$data, rv$X_names, rv$def)

    dat <- rv$data

    X_cont <- rv$def$Parameter[tolower(rv$def$Type) == "continuous" & rv$def$Parameter %in% rv$X_names]
    X_cat  <- rv$def$Parameter[tolower(rv$def$Type) == "categorical" & rv$def$Parameter %in% rv$X_names]

    validate(need(length(X_cont) > 0, "At least one continuous X is required for GP (Type='continuous')."))
    validate(need(y_name %in% names(dat), paste0(y_name, " not found in data.")))

    # Feature 1: 選択されたY
    yorg <- as.numeric(dat[[y_name]])

    # Yeo-Johnson 変換（負値にも対応、lambda=NULL で恒等変換）
    lambda <- NULL
    # if (!is.null(input$use_yeojohnson) && isTRUE(input$use_yeojohnson)) {
    #   lv <- suppressWarnings(as.numeric(input$yj_lambda))
    #   if (is.finite(lv)) lambda <- lv
    # }
    # y <- fwd_y(yorg, lambda = lambda)
    y <- yorg

    # Feature 2: 派生変数を含む連続変数行列
    all_cont <- c(X_cont, rv$derived_cols)
    Xraw_cont <- as.matrix(dat[, all_cont, drop = FALSE])
    storage.mode(Xraw_cont) <- "double"

    Z_cat <- NULL
    if (length(X_cat) > 0) {
      Z_cat <- as.data.frame(dat[, X_cat, drop = FALSE])
      names(Z_cat) <- X_cat
      for (nm in X_cat) Z_cat[[nm]] <- as.character(Z_cat[[nm]])
    }

    X <- cbind(1, Xraw_cont)
    Z <- Xraw_cont

    n_data <- nrow(dat)
    n_beta <- ncol(X)
    if (n_data < n_beta) {
      stop(sprintf(
        "Number of data points (%d) is smaller than number of linear parameters (%d). Please reduce the number of derived/continuous terms or increase the number of data points.",
        n_data, n_beta
      ))
    }

    std <- standardize_fit(X, Z, y, standardize_X = TRUE, intercept_col = 1L)

    sf2        <- 1.0
    ell        <- as.numeric(input$hp2)
    sigma2     <- as.numeric(input$hp3)
    sigma_cat2 <- 0.5
    p          <- ncol(std$X)

    # β 事前分布パラメータ（Modelシートから: mu0_map / sig0_map; 未指定はデフォルト）
    var_labels <- c("(intercept)", all_cont)
    mu0  <- numeric(p)
    sig0 <- numeric(p)
    
    get_prior_value <- function(map_by_target, y_name, lbl) {
      v <- NULL
      if (!is.null(map_by_target[[y_name]])) v <- map_by_target[[y_name]][[lbl]]
      if (is.null(v) && !is.null(map_by_target[["All"]])) v <- map_by_target[["All"]][[lbl]]
      if (is.null(v) && !is.null(map_by_target[["default"]])) v <- map_by_target[["default"]][[lbl]]
      v
    }
    
    for (i in seq_len(p)) {
      lbl    <- if (i <= length(var_labels)) var_labels[i] else paste0("col", i)
      mu_val <- get_prior_value(rv$model_params$mu0_map,  y_name, lbl)
      sg_val <- get_prior_value(rv$model_params$sig0_map, y_name, lbl)
      
      mu0[i]  <- if (!is.null(mu_val) && is.finite(mu_val)) mu_val else 0
      sig0[i] <- if (!is.null(sg_val) && is.finite(sg_val) && sg_val > 0) sg_val else 100
    }
    
    prior_std <- prior_to_standardized_scale(
      mu0_orig = mu0,
      sig0_orig = sig0,
      std = std,
      all_cont = all_cont
    )
    
    mu0_fit  <- prior_std$mu0
    sig0_fit <- prior_std$sig0
    Sigma0   <- diag(sig0_fit, p)

    validate(need(is.finite(ell)    && ell    > 0, "hp2 (ell) must be > 0"))
    validate(need(is.finite(sigma2) && sigma2 >= 0, "hp3 (sigma2) must be >= 0"))

    fit <- fit_semiparam_bayes(
      y = std$y, X = std$X, Z = std$Z,
      Z_cat     = Z_cat,
      mu0       = mu0_fit, Sigma0 = Sigma0,
      sigma2    = sigma2, ell = ell, sf2 = sf2,
      sigma_cat2 = sigma_cat2
    )
    #betaの元スケール
    mu_beta_orig <- beta_to_original_scale(
      mu_beta_std = fit$mu_beta,
      std = std,
      all_cont = all_cont
    )
    
    y_pred   <- destandardize_y(fit$y_hat, std)
    var_s    <- sqrt(pmax(as.numeric(fit$eps_var_hat), 0))
    var_pred <- destandardize_y_sd(var_s, std)

    rv$fits[[y_name]] <- list(
      fit       = fit,
      std       = std,
      lambda    = lambda,
      X_cont    = X_cont,
      X_cat     = X_cat,
      all_cont  = all_cont,
      Xraw_cont = Xraw_cont,
      Z_cat     = Z_cat,
      yorg      = yorg,
      y_pred    = y_pred,
      var_pred  = var_pred,
      y_name    = y_name,
      mu_beta_orig = mu_beta_orig,
      mu0_orig     = mu0,
      sig0_orig    = sig0,
      mu0_fit      = mu0_fit,
      sig0_fit     = sig0_fit
    )
  }

  # Fit model ボタン: 全Yをフィット
  observeEvent(input$btn_fit, {
    req(rv$Y_names)
    
    if (!is.null(rv$error_msg) && nzchar(rv$error_msg)) return(NULL)
    
    rv$fits <- list()
    rv$cand <- NULL
    rv$optimize_status_msg <- "No optimize results with the current models. Please run Suggest next experiments."
    for (yn in rv$Y_names) do_fit_one(yn)
    rv$y_view <- rv$Y_names[1]
    rv$fit <- rv$fits[[rv$y_view]]
    rv$last_fit_hp2       <- input$hp2
    rv$last_fit_hp3       <- input$hp3
    #rv$last_fit_use_yj    <- isTRUE(input$use_yeojohnson)
    #rv$last_fit_yj_lambda <- if (isTRUE(input$use_yeojohnson)) input$yj_lambda else NA_real_
  })

  # Refit ボタン: 現在表示中のYだけ再フィット
  observeEvent(input$btn_refit, {
    # upload未完了 or エラー時は何もしない
    if (!isTRUE(rv$upload_valid)) return(NULL)
    
    req(rv$y_view)
    
    do_fit_one(rv$y_view)
    rv$fit <- rv$fits[[rv$y_view]]
    
    rv$last_fit_hp2       <- input$hp2
    rv$last_fit_hp3       <- input$hp3
    #rv$last_fit_use_yj    <- isTRUE(input$use_yeojohnson)
    #rv$last_fit_yj_lambda <- if (isTRUE(input$use_yeojohnson)) input$yj_lambda else NA_real_
    
    rv$cand <- NULL
    rv$optimize_status_msg <- paste0(
      "Optimize results were cleared because the model for ",
      rv$y_view,
      " was refit. Please run Suggest next experiments again."
    )
  })
  
  output$ui_btn_fit <- renderUI({
    has_upload_error <- !is.null(rv$error_msg) && nzchar(rv$error_msg) || is.null(rv$Y_names)
    if (has_upload_error) {
      return(
        tags$button(
          "Fit all Y",
          class = "btn btn-default btn-wide",
          style = "background-color:#d9d9d9; color:#888; border-color:#d0d0d0; cursor:not-allowed;",
          disabled = NA
        )
      )
    }
    dirty <- isTRUE(tryCatch(model_dirty_reactive(), error = function(e) FALSE))
    cls <- if (dirty) "btn-wide btn-primary" else "btn-wide"
    actionButton("btn_fit", "Fit all Y", class = cls)
  })
  
  output$ui_btn_refit <- renderUI({
    has_upload_error <- !is.null(rv$error_msg) && nzchar(rv$error_msg) || is.null(rv$Y_names)
    if (has_upload_error) {
      return(
        tags$button(
          "Refit current Y",
          class = "btn btn-default btn-wide",
          style = "background-color:#d9d9d9; color:#888; border-color:#d0d0d0; cursor:not-allowed;",
          disabled = NA
        )
      )
    }
    
    dirty <- isTRUE(tryCatch(model_dirty_reactive(), error = function(e) FALSE))
    cls <- if (dirty) "btn-wide btn-primary" else "btn-wide"
    actionButton("btn_refit", "Refit current Y", class = cls)
  })

  # ══════════════════════════════════════════════════════════
  # 2. Model タブ
  # ══════════════════════════════════════════════════════════
  build_fit_info_lines <- function(fw) {
    fit    <- fw$fit
    y_name <- fw$y_name
    lambda <- fw$lambda
    
    beta_disp <- fw$mu_beta_orig
    if (is.null(beta_disp) || length(beta_disp) == 0) {
      beta_disp <- fit$mu_beta
    }
    
    p <- length(beta_disp)
    validate(need(p >= 1, "No beta coefficients are available for display."))
    
    x_labels <- c("(intercept)", fw$all_cont)
    if (length(x_labels) < p) {
      x_labels <- c(x_labels, paste0("col", seq_len(p - length(x_labels))))
    }
    x_labels <- x_labels[seq_len(p)]
    
    term_strs <- character(p)
    term_strs[1] <- sprintf("%.4f·1", beta_disp[1])
    if (p >= 2) {
      for (i in 2:p) {
        term_strs[i] <- sprintf("%.4f·%s", beta_disp[i], x_labels[i])
      }
    }
    
    linear_eq <- paste0(y_name, " = ", paste(term_strs, collapse = " + "), " + u + \u03b5")
    
    beta_lines <- sprintf(
      "  mu_beta[%d]  %-20s = %+.6f",
      seq_len(p), paste0("(", x_labels, ")"), beta_disp
    )
    
    c(
      "Semi-parametric Bayesian regression",
      linear_eq,
      "beta ~ N(mu0, Sigma0),  u ~ GP(0, K),  \u03b5 ~ N(0, \u03c3\u00b2 I)",
      "",
      "[Posterior beta | y] (original scale)",
      beta_lines,
      "",
      "[Hyperparameters]",
      sprintf("theta1 (RBF scale)       = %.4f", fit$sf2),
      sprintf("theta2 (lengthscale)     = %.4f", fit$ell),
      sprintf("sigma2 (noise var)       = %.6f", fit$sigma2),
      sprintf("sigma_cat (cat. var.)    = %.6f", fit$sigma_cat2),
      "",
      {
        resid_o      <- fw$yorg - fw$y_pred
        eps_var_orig <- var(resid_o)
        rmse_orig    <- sqrt(mean(resid_o^2))
        ss_res       <- sum(resid_o^2)
        R2_orig      <- 1 - ss_res / sum((fw$yorg - mean(fw$yorg))^2)
        c(
          "[Residuals] (original scale)",
          sprintf("eps var.= %.4f,  RMSE = %.4f,  R2 = %.4f",
                  eps_var_orig, rmse_orig, R2_orig)
        )
      }
    )
  }
  
  output$fit_info <- renderPrint({
    req(rv$fit)
    cat(paste(build_fit_info_lines(rv$fit), collapse = "\n"))
  })

  output$plot_pred_vs_obs <- renderPlot({
    req(rv$fit)
    fit    <- rv$fit$fit
    std    <- rv$fit$std
    lambda <- rv$fit$lambda
    y_name <- rv$fit$y_name

    pred_s <- predict_semiparam_bayes(
      fit, Xnew = fit$X, Znew = fit$Z, Z_cat_new = fit$Z_cat,
      return_components = FALSE
    )
    yhat_s <- pred_s$mean
    yhat   <- destandardize_y(yhat_s, std)
    if (exists("inv_y", mode = "function")) yhat <- inv_y(yhat, lambda = lambda)

    yobs <- rv$fit$yorg
    rng  <- range(c(yobs, yhat), na.rm = TRUE)

    par(mar = c(4,4,1,1))
    plot(yobs, yhat, pch = 19,
         xlab = paste0("Obtained ", y_name),
         ylab = paste0("Prediction ", y_name),
         xlim = rng, ylim = rng)
    abline(0, 1, lwd = 2)
    text(x = max(yobs), y = min(yhat),
         labels = sprintf("R2 = %.4f", fit$R2),
         adj = c(1, 0))
  })

  # Model / Analyze タブ内 Y セレクター（rv$y_view を更新し rv$fit を切り替え）
  make_y_tab_selector <- function(input_id) {
    renderUI({
      req(length(rv$fits) > 0)
      if (length(rv$Y_names) <= 1) return(NULL)
      selectInput(input_id, "Select Y",
                  choices  = names(rv$fits),
                  selected = rv$y_view %||% names(rv$fits)[1])
    })
  }
  output$ui_y_view_model   <- make_y_tab_selector("y_view_model_sel")
  output$ui_y_view_analyze <- make_y_tab_selector("y_view_analyze_sel")

  observeEvent(input$y_view_model_sel, {
    rv$y_view <- input$y_view_model_sel
    if (!is.null(rv$fits[[rv$y_view]])) rv$fit <- rv$fits[[rv$y_view]]
  })
  observeEvent(input$y_view_analyze_sel, {
    rv$y_view <- input$y_view_analyze_sel
    if (!is.null(rv$fits[[rv$y_view]])) rv$fit <- rv$fits[[rv$y_view]]
  })

  # ══════════════════════════════════════════════════════════
  # Model params ダウンロード（fitting info タブの Save ボタン）
  # ── Model シート形式 ──
  #   type       | parameter              | value
  #   rbf        | theta1                 | <sf2>
  #   rbf        | theta2                 | <ell>
  #   rbf        | sigma2                 | <sigma2>
  #   prior      | (intercept)_mu         | <mu0>
  #   prior      | (intercept)_var        | <sig0>
  #   prior      | X1_mu / X1_var         | ...
  #   posterior  | (intercept)_mu_beta    | <fitted mu_beta>
  #   posterior  | X1_mu_beta             | ...
  # ══════════════════════════════════════════════════════════
  output$download_model <- downloadHandler(
    filename = function() {
      base_name <- if (!is.null(rv$upload_name) && nzchar(rv$upload_name)) {
        tools::file_path_sans_ext(basename(rv$upload_name))
      } else {
        "result"
      }
      paste0(base_name, "_", format(Sys.time(), "%Y%m%d%H%M"), ".xlsx")
    },
    content  = function(file) {
      req(rv$fits, rv$upload_path)
      
      # アップロード済み Excel の全シートを読み込み
      src_path   <- rv$upload_path
      all_sheets <- excel_sheets(src_path)
      
      sheets_list <- lapply(all_sheets, function(s) {
        tryCatch(as.data.frame(read_excel(src_path, sheet = s)),
                 error = function(e) data.frame())
      })
      names(sheets_list) <- all_sheets
      
      # ── Fit info シート: fitting model information を全Y分保存 ──
      y_names <- names(rv$fits)
      fit_blocks <- list()
      
      for (yn in y_names) {
        fw <- rv$fits[[yn]]
        lines <- build_fit_info_lines(fw)
        
        block_df <- data.frame(
          Output = c(yn, rep("", length(lines) - 1), ""),
          Line   = c(lines, ""),
          stringsAsFactors = FALSE
        )
        fit_blocks[[yn]] <- block_df
      }
      
      fit_info_df <- do.call(rbind, fit_blocks)
      rownames(fit_info_df) <- NULL
      
      sheets_list[["Fit info"]] <- fit_info_df
      
      # ── Optimize シート: 候補があれば保存 ──
      if (!is.null(rv$cand) && nrow(rv$cand) > 0) {
        opt_df <- rv$cand
        if ("Rank" %in% names(opt_df)) {
          opt_df[["Rank"]] <- as.integer(opt_df[["Rank"]])
        }
        sheets_list[["Optimize"]] <- opt_df
      }
      
      write_xlsx(sheets_list, path = file)
    }
  )

  # ══════════════════════════════════════════════════════════
  # 3. Analyze タブ
  # ══════════════════════════════════════════════════════════
  output$fit_info_analyze <- renderPrint({
    req(rv$fit)
    cat(paste(build_fit_info_lines(rv$fit), collapse = "\n"))
  })
  
  output$ui_x12_select <- renderUI({
    req(rv$X_names)
    fluidRow(
      column(6, selectInput("x1", "X (horizontal)", choices = rv$X_names, selected = rv$X_names[[1]])),
      column(6, selectInput("x2", "X (vertical)",   choices = rv$X_names, selected = rv$X_names[[1]]))
    )
  })

  get_type <- function(xn) {
    rr <- rv$def[rv$def$Parameter == xn, , drop = FALSE]
    if (nrow(rr) == 0) return(NA_character_)
    tolower(as.character(rr$Type[1]))
  }

  get_fix_value_def <- function(xn) {
    rr <- rv$def[rv$def$Parameter == xn, , drop = FALSE]
    if (nrow(rr) == 0) return(NA)
    tp <- tolower(trimws(as.character(rr$Type[1])))
    if (tp == "continuous") {
      v <- suppressWarnings(as.numeric(rr$standard_num[1]))
      if (!is.finite(v)) {
        j <- match(xn, rv$fit$all_cont)
        if (!is.na(j) && !is.null(rv$fit$Xraw_cont))
          v <- median(as.numeric(rv$fit$Xraw_cont[, j]), na.rm = TRUE)
        else v <- 0
      }
      return(v)
    }
    v <- as.character(rr$Standard_raw[1])
    if (is.na(v) || v == "") v <- as.character(rr$Min_raw[1])
    v
  }

  get_levels_ordered <- function(cat_name) {
    dr <- rv$def[rv$def$Parameter == cat_name, , drop = FALSE]
    if (nrow(dr) == 0) return(character(0))
    lv <- c(dr$Min_raw[1], dr$Standard_raw[1], dr$Max_raw[1])
    lv <- lv[!is.na(lv) & trimws(lv) != ""]
    lv <- unique(as.character(lv))
    if (!is.null(rv$fit$Z_cat) && cat_name %in% names(rv$fit$Z_cat))
      lv <- unique(c(lv, unique(as.character(rv$fit$Z_cat[[cat_name]]))))
    lv
  }

  get_grid_cont <- function(xn, max_n = 20, default_n = 100) {
    rr <- rv$def[rv$def$Parameter == xn, , drop = FALSE]
    mn <- if (nrow(rr) > 0) as.numeric(rr$min_num[1])  else NA_real_
    mx <- if (nrow(rr) > 0) as.numeric(rr$max_num[1])  else NA_real_
    it <- if (nrow(rr) > 0) as.numeric(rr$Interval[1]) else NA_real_
    j  <- match(xn, rv$fit$all_cont)
    if (!is.finite(mn) || !is.finite(mx) || mx <= mn) {
      if (!is.na(j) && !is.null(rv$fit$Xraw_cont)) {
        mn <- min(rv$fit$Xraw_cont[, j], na.rm = TRUE)
        mx <- max(rv$fit$Xraw_cont[, j], na.rm = TRUE)
      }
    }
    if (is.na(it) || !is.finite(it) || it <= 0)
      seq(mn, mx, length.out = default_n)
    else
      make_grid_1d(mn, mx, it, max_n = max_n)
  }

  pred_wrap <- function(Xcont_new, Zcat_new) {
    Xcont_new <- as.matrix(Xcont_new)
    storage.mode(Xcont_new) <- "double"
    Xnew  <- cbind(1, Xcont_new)
    Znew  <- Xcont_new
    new_s <- standardize_apply(Xnew, Znew, rv$fit$std)
    pr    <- predict_semiparam_bayes(
      rv$fit$fit,
      Xnew          = new_s$X,
      Znew          = new_s$Z,
      Z_cat_new     = Zcat_new,
      return_components = TRUE
    )
    mu_s <- as.numeric(pr$mean)
    sd_s <- sqrt(pmax(as.numeric(pr$var_total), 0))
    list(
      mu = as.numeric(destandardize_y(mu_s, rv$fit$std)),
      sd = as.numeric(destandardize_y_sd(sd_s, rv$fit$std))
    )
  }

  # 予測用連続行列（基本X＋派生変数）を構築
  build_xcont_new <- function(base_df, n_rows) {
    # base_df: data.frame with base X_cont columns
    all_cont <- rv$fit$all_cont
    Xcont_new <- matrix(NA_real_, nrow = n_rows, ncol = length(all_cont))
    colnames(Xcont_new) <- all_cont

    # 基本変数をコピー
    for (nm in rv$fit$X_cont) {
      if (nm %in% colnames(base_df))
        Xcont_new[, nm] <- base_df[[nm]]
    }

    # 派生変数を式から計算
    for (nm in rv$derived_cols) {
      formula_str <- rv$derived_formulas[[nm]]
      if (!is.null(formula_str) && nchar(trimws(formula_str)) > 0) {
        tryCatch({
          Xcont_new[, nm] <- eval(parse(text = formula_str), envir = as.data.frame(base_df))
        }, error = function(e) { Xcont_new[, nm] <- NA_real_ })
      } else if (nm %in% names(base_df)) {
        Xcont_new[, nm] <- base_df[[nm]]
      }
    }
    Xcont_new
  }

  output$plot_1d <- renderPlot({
    req(rv$fit, rv$def, rv$X_names, input$x1)

    y_name <- rv$fit$y_name
    X_cont <- rv$fit$X_cont
    X_cat  <- rv$fit$X_cat
    x1     <- input$x1
    x2     <- if (!is.null(input$x2) && input$x2 != "None") input$x2 else x1
    t1     <- get_type(x1)
    t2     <- get_type(x2)

    validate(need(!is.na(t1) && !is.na(t2), "Type in Definition must be 'continuous' or 'categorical'."))

    y_obs <- as.numeric(rv$fit$yorg)

    # ── CASE 1: 1D line (same continuous) ──
    if (t1 == "continuous" && t2 == "continuous" && x1 == x2) {
      xg <- get_grid_cont(x1, max_n = 20, default_n = 100)
      base_df <- data.frame(matrix(NA_real_, nrow = length(xg), ncol = length(X_cont)))
      colnames(base_df) <- X_cont
      for (nm in X_cont) base_df[[nm]] <- get_fix_value_def(nm)
      base_df[[x1]] <- xg

      Xcont_new <- build_xcont_new(base_df, length(xg))
      Zcat_new  <- NULL
      if (length(X_cat) > 0) {
        Zcat_new <- as.data.frame(matrix(NA_character_, nrow = length(xg), ncol = length(X_cat)))
        names(Zcat_new) <- X_cat
        for (nm in X_cat) Zcat_new[[nm]] <- as.character(get_fix_value_def(nm))
      }
      pr <- pred_wrap(Xcont_new, Zcat_new)
      mu <- pr$mu; sd <- pr$sd
      lo <- mu - sd; hi <- mu + sd
      ok <- is.finite(xg) & is.finite(mu) & is.finite(lo) & is.finite(hi)
      validate(need(any(ok), "No finite predictions."))

      jx <- match(x1, X_cont)
      x_obs <- if (!is.na(jx)) as.numeric(rv$fit$Xraw_cont[, jx]) else NULL
      ylim  <- range(c(lo[ok], hi[ok], y_obs), na.rm = TRUE)
      if (!all(is.finite(ylim))) ylim <- c(0, 1)

      par(mar = c(4,4,1,1))
      plot(xg[ok], mu[ok], type = "l", lwd = 2, xlab = x1, ylab = y_name, ylim = ylim)
      lines(xg[ok], lo[ok], lty = 2)
      lines(xg[ok], hi[ok], lty = 2)
      if (!is.null(x_obs)) points(x_obs, y_obs, pch = 19)
      return(invisible())
    }

    # ── CASE 2: 2D contour (two different continuous) ──
    if (t1 == "continuous" && t2 == "continuous" && x1 != x2) {
      x1g <- get_grid_cont(x1, max_n = 10, default_n = 20)
      x2g <- get_grid_cont(x2, max_n = 10, default_n = 20)
      grid <- expand.grid(x1g, x2g); names(grid) <- c(x1, x2)

      base_df <- data.frame(matrix(NA_real_, nrow = nrow(grid), ncol = length(X_cont)))
      colnames(base_df) <- X_cont
      for (nm in X_cont) base_df[[nm]] <- get_fix_value_def(nm)
      base_df[[x1]] <- grid[[x1]]
      base_df[[x2]] <- grid[[x2]]

      Xcont_new <- build_xcont_new(base_df, nrow(grid))
      Zcat_new  <- NULL
      if (length(X_cat) > 0) {
        Zcat_new <- as.data.frame(matrix(NA_character_, nrow = nrow(grid), ncol = length(X_cat)))
        names(Zcat_new) <- X_cat
        for (nm in X_cat) Zcat_new[[nm]] <- as.character(get_fix_value_def(nm))
      }
      pr <- pred_wrap(Xcont_new, Zcat_new)
      mu <- pr$mu
      ok <- is.finite(mu)
      validate(need(any(ok), "No finite predictions."))

      zmat <- matrix(mu, nrow = length(x1g), ncol = length(x2g), byrow = FALSE)
      cols  <- colorRampPalette(c("#0d0887","#6a00a8","#b12a90","#e16462","#fca636","#f0f921"))(50)
      par(mar = c(4,4,1,1))
      image(x1g, x2g, zmat, col = cols, xlab = x1, ylab = x2)
      contour(x1g, x2g, zmat, add = TRUE)
      j1 <- match(x1, X_cont); j2 <- match(x2, X_cont)
      if (!is.na(j1) && !is.na(j2))
        points(rv$fit$Xraw_cont[, j1], rv$fit$Xraw_cont[, j2], pch = 19, col = "white")
      return(invisible())
    }

    # ── CASE 3: continuous + categorical ──
    if ((t1 == "continuous" && t2 == "categorical" && x1 != x2) ||
        (t1 == "categorical" && t2 == "continuous" && x1 != x2)) {
      x_cont <- if (t1 == "continuous") x1 else x2
      x_cat  <- if (t1 == "categorical") x1 else x2
      xg <- get_grid_cont(x_cont, max_n = 20, default_n = 100)
      lv <- get_levels_ordered(x_cat)
      validate(need(length(lv) >= 1, paste0("No categorical levels for ", x_cat)))
      m <- length(xg) * length(lv)

      base_df <- data.frame(matrix(NA_real_, nrow = m, ncol = length(X_cont)))
      colnames(base_df) <- X_cont
      for (nm in X_cont) base_df[[nm]] <- get_fix_value_def(nm)
      base_df[[x_cont]] <- rep(xg, times = length(lv))

      Xcont_new <- build_xcont_new(base_df, m)
      Zcat_new  <- NULL
      if (length(X_cat) > 0) {
        Zcat_new <- as.data.frame(matrix(NA_character_, nrow = m, ncol = length(X_cat)))
        names(Zcat_new) <- X_cat
        for (nm in X_cat) Zcat_new[[nm]] <- as.character(get_fix_value_def(nm))
        Zcat_new[[x_cat]] <- rep(as.character(lv), each = length(xg))
      } else {
        validate(need(FALSE, "Model has no categorical inputs but one axis is categorical."))
      }
      pr <- pred_wrap(Xcont_new, Zcat_new)
      mu <- pr$mu; ok <- is.finite(mu)
      validate(need(any(ok), "No finite predictions."))

      ylim <- range(c(mu[ok], y_obs), na.rm = TRUE)
      if (!all(is.finite(ylim))) ylim <- c(0, 1)
      par(mar = c(4,4,1,1))
      plot(xg, numeric(length(xg)), type = "n", xlab = x_cont, ylab = paste0("Predicted ", y_name), ylim = ylim)
      for (k in seq_along(lv)) {
        idx <- ((k-1)*length(xg)+1):(k*length(xg))
        lines(xg, mu[idx], lwd = 2, col = k)
      }
      legend("topleft", legend = lv, lwd = 2, bty = "n", title = x_cat, col = seq_along(lv))
      jx <- match(x_cont, X_cont)
      if (!is.na(jx) && !is.null(rv$fit$Xraw_cont))
        points(rv$fit$Xraw_cont[, jx], y_obs, pch = 19)
      return(invisible())
    }

    # ── CASE 4: categorical (same) ──
    if (t1 == "categorical" && t2 == "categorical" && x1 == x2) {
      lv <- get_levels_ordered(x1)
      validate(need(length(lv) >= 1, "No categorical levels."))
      n_lv <- length(lv)

      base_df <- data.frame(matrix(NA_real_, nrow = n_lv, ncol = length(X_cont)))
      colnames(base_df) <- X_cont
      for (nm in X_cont) base_df[[nm]] <- get_fix_value_def(nm)

      Xcont_new <- build_xcont_new(base_df, n_lv)
      Zcat_new  <- as.data.frame(matrix(NA_character_, nrow = n_lv, ncol = length(X_cat)))
      names(Zcat_new) <- X_cat
      for (nm in X_cat) Zcat_new[[nm]] <- as.character(get_fix_value_def(nm))
      Zcat_new[[x1]] <- as.character(lv)

      pr <- pred_wrap(Xcont_new, Zcat_new)
      mu <- pr$mu; sd <- pr$sd
      ok <- is.finite(mu) & is.finite(sd)
      validate(need(any(ok), "No finite predictions."))

      ylim <- range(c((mu-sd)[ok], (mu+sd)[ok], y_obs), na.rm = TRUE)
      if (!all(is.finite(ylim))) ylim <- c(0, 1)
      xpos <- seq_along(lv)
      par(mar = c(6,4,1,1))
      plot(xpos, mu, type = "n", xaxt = "n", xlab = x1,
           ylab = paste0("Predicted ", y_name), ylim = ylim)
      axis(1, at = xpos, labels = lv, las = 2)
      arrows(xpos, mu - sd, xpos, mu + sd, angle = 90, code = 3, length = 0.05)
      points(xpos, mu, pch = 1, cex = 1.2)
      if (!is.null(rv$fit$Z_cat) && x1 %in% names(rv$fit$Z_cat)) {
        x_tr <- as.character(rv$fit$Z_cat[[x1]])
        idx  <- match(x_tr, lv)
        ok2  <- !is.na(idx) & is.finite(y_obs)
        if (any(ok2)) points(jitter(idx[ok2], amount = 0.03), y_obs[ok2], pch = 19, col = rgb(0,0,0,0.7))
      }
      return(invisible())
    }

    # ── CASE 5: categorical vs categorical (different) ──
    par(mar = c(4,4,1,1))
    plot.new()
    text(0.5, 0.5, "Not available: categorical vs categorical (different variables)", cex = 1.1)
  })

  # ══════════════════════════════════════════════════════════
  # 4. Optimize タブ
  # ══════════════════════════════════════════════════════════
  output$ui_optimize_status <- renderUI({
    if (is.null(rv$optimize_status_msg) || !nzchar(rv$optimize_status_msg)) return(NULL)
    div(class = "note", rv$optimize_status_msg)
  })
  
  output$ui_btn_suggest <- renderUI({
    req(length(rv$fits) > 0)
    fitted_label <- paste(names(rv$fits), collapse = ", ")
    div(
      actionButton("btn_suggest", "Suggest next experiments", class = "btn-wide btn-primary"),
      div(class = "note", style = "margin-top:6px;",
          paste0("Fitted Y: ", fitted_label,
                 " | Optimize Yn: top 2 per Y (κ=0) | Optimize All: top 3 by desirability D (geometric mean, κ=0) | Explore Yn: top 2 per Y (κ=2)"))
    )
  })

  observeEvent(input$btn_suggest, {
    req(rv$def, rv$X_names)
    fitted_Ys <- names(rv$fits)
    if (length(fitted_Ys) == 0) { rv$error_msg <- "Please fit the model first."; return(NULL) }
    rv$error_msg <- NULL
    rv$optimize_status_msg <- NULL
    def2   <- rv$def
    Xnames <- rv$X_names

    def2$Type <- tolower(trimws(def2$Type))

    get_cat_levels_loc <- function(nm) {
      row_def <- def2[def2$Parameter == nm, , drop = FALSE]
      if (nrow(row_def) == 0) return(character(0))
      levs <- unique(na.omit(trimws(c(row_def$Min_raw[1], row_def$Standard_raw[1], row_def$Max_raw[1]))))
      levs <- levs[levs != ""]
      if (length(levs) == 0 && nm %in% names(rv$data))
        levs <- unique(na.omit(as.character(rv$data[[nm]])))
      levs
    }

    # 候補リスト（基本変数のみ）
    cand_list <- vector("list", length(Xnames))
    names(cand_list) <- Xnames

    for (nm in Xnames) {
      row_def <- def2[def2$Parameter == nm, , drop = FALSE]
      if (nrow(row_def) == 0) { rv$error_msg <- paste("Definition missing for", nm); return(NULL) }
      if (row_def$Type[1] == "continuous") {
        mn <- row_def$min_num[1]; mx <- row_def$max_num[1]; h <- row_def$Interval[1]
        if (!is.finite(mn) || !is.finite(mx) || mx <= mn) {
          mn <- min(rv$data[[nm]], na.rm = TRUE)
          mx <- max(rv$data[[nm]], na.rm = TRUE)
        }
        cand_list[[nm]] <- if (is.na(h) || !is.finite(h) || h <= 0) seq(mn, mx, length.out = 21) else seq(mn, mx, by = h)
        if (length(cand_list[[nm]]) < 2) cand_list[[nm]] <- c(mn, mx)
      } else if (row_def$Type[1] == "categorical") {
        levs <- get_cat_levels_loc(nm)
        if (length(levs) == 0) { rv$error_msg <- paste("No levels for", nm); return(NULL) }
        cand_list[[nm]] <- levs
      } else { rv$error_msg <- paste("Unknown Type for", nm); return(NULL) }
    }

    N_SAMPLE   <- 100
    MAX_CORNERS <- 2048
    set.seed(1)

    lhs_unit <- function(n, d) {
      U <- matrix(NA_real_, n, d)
      for (j in seq_len(d)) { perm <- sample.int(n, n, replace = FALSE); U[, j] <- (perm - runif(n)) / n }
      U
    }

    n_all <- prod(vapply(cand_list, length, integer(1)))
    if (n_all <= N_SAMPLE) {
      grid_df <- expand.grid(cand_list, KEEP.OUT.ATTRS = FALSE, stringsAsFactors = FALSE)
    } else {
      X_cont_base <- def2$Parameter[def2$Type == "continuous"  & def2$Parameter %in% Xnames]
      X_cat_base  <- def2$Parameter[def2$Type == "categorical" & def2$Parameter %in% Xnames]
      grid_df <- data.frame(matrix(nrow = N_SAMPLE, ncol = length(Xnames))); names(grid_df) <- Xnames
      for (nm in X_cat_base) grid_df[[nm]] <- sample(cand_list[[nm]], size = N_SAMPLE, replace = TRUE)
      if (length(X_cont_base) > 0) {
        U <- lhs_unit(N_SAMPLE, length(X_cont_base)); colnames(U) <- X_cont_base
        for (j in seq_along(X_cont_base)) {
          nm <- X_cont_base[j]; vv <- cand_list[[nm]]; m <- length(vv)
          grid_df[[nm]] <- vv[pmin(m, pmax(1, floor(U[, j] * m) + 1L))]
        }
      }
    }

    # コーナー点追加
    ext_list   <- lapply(Xnames, function(nm) { vv <- cand_list[[nm]]; c(vv[1], vv[length(vv)]) })
    names(ext_list) <- Xnames
    n_corners <- prod(vapply(ext_list, length, integer(1)))
    if (n_corners <= MAX_CORNERS)
      grid_df <- unique(rbind(grid_df, expand.grid(ext_list, KEEP.OUT.ATTRS = FALSE, stringsAsFactors = FALSE)))

    # Feature 2: 派生変数を計算してgrid_dfに追加
    for (col in rv$derived_cols) {
      formula_str <- rv$derived_formulas[[col]]
      if (!is.null(formula_str) && nchar(trimws(formula_str)) > 0) {
        tryCatch({
          grid_df[[col]] <- eval(parse(text = formula_str), envir = grid_df)
        }, error = function(e) { grid_df[[col]] <- NA_real_ })
      }
    }

    # Feature 3: 制約フィルタリング
    if (length(rv$constraints) > 0) {
      keep <- rep(TRUE, nrow(grid_df))
      for (expr in rv$constraints) {
        tryCatch({
          res <- eval(parse(text = expr), envir = as.list(grid_df))
          if (length(res) == nrow(grid_df)) keep <- keep & as.logical(res)
        }, error = function(e) NULL)
      }
      keep[is.na(keep)] <- FALSE
      grid_df <- grid_df[keep, , drop = FALSE]
      if (nrow(grid_df) == 0) { rv$error_msg <- "All candidates were filtered out by constraints."; return(NULL) }
    }

    # 連続/カテゴリ分割
    X_cont_all <- c(def2$Parameter[def2$Type == "continuous" & def2$Parameter %in% Xnames], rv$derived_cols)
    X_cont_all <- X_cont_all[X_cont_all %in% names(grid_df)]
    X_cat_base <- def2$Parameter[def2$Type == "categorical" & def2$Parameter %in% Xnames]

    Xnew_cont <- if (length(X_cont_all) > 0) {
      m <- as.matrix(grid_df[, X_cont_all, drop = FALSE]); storage.mode(m) <- "double"; m
    } else matrix(numeric(0), nrow = nrow(grid_df), ncol = 0)

    Z_cat_new <- NULL
    if (length(X_cat_base) > 0) {
      Z_cat_new <- as.data.frame(grid_df[, X_cat_base, drop = FALSE])
      for (nm in X_cat_base) Z_cat_new[[nm]] <- as.character(Z_cat_new[[nm]])
    }

    Xnew <- cbind(1, Xnew_cont)
    Znew <- Xnew_cont

    # ── 各 Y について予測 ────────────────────────────────
    all_mu <- list()
    all_sd <- list()
    for (yn in fitted_Ys) {
      fw <- rv$fits[[yn]]
      ns <- tryCatch(standardize_apply(Xnew, Znew, fw$std), error = function(e) NULL)
      if (is.null(ns)) next
      pr <- tryCatch(
        predict_semiparam_bayes(fw$fit, Xnew = ns$X, Znew = ns$Z,
                                Z_cat_new = Z_cat_new, return_components = TRUE),
        error = function(e) NULL)
      if (is.null(pr)) next
      all_mu[[yn]] <- as.numeric(destandardize_y(pr$mean, fw$std))
      all_sd[[yn]] <- as.numeric(destandardize_y_sd(sqrt(pmax(pr$var_total, 0)), fw$std))
    }
    if (length(all_mu) == 0) { rv$error_msg <- "Prediction failed for all Y."; return(NULL) }

    # ── 満足度関数（Derringer-Suich 簡略版）────────────
    # 各 Y の UCB/LCB スコアを [0,1] に正規化し幾何平均を取る
    # ── 満足度関数（全Y統合）─────────────────────────────
    # ── 満足度関数（全Y統合）─────────────────────────────
    # ── 満足度関数（全Y統合）─────────────────────────────
    compute_D <- function(kappa) {
      d_list <- lapply(names(all_mu), function(yn) {
        mu_k <- all_mu[[yn]]
        sd_k <- all_sd[[yn]]
        defY <- def2[def2$Parameter == yn, , drop = FALSE]
        purp <- if (nrow(defY) > 0 && !is.na(defY$Purpose[1])) as.character(defY$Purpose[1]) else ""
        
        score <- ucb_score(mu_k, sd_k, purp, kappa)
        lo <- min(score, na.rm = TRUE)
        hi <- max(score, na.rm = TRUE)
        
        if (hi > lo) {
          pmax(0, pmin(1, (score - lo) / (hi - lo)))
        } else {
          rep(0.5, length(score))
        }
      })
      
      d_mat <- do.call(cbind, d_list)
      apply(d_mat, 1, function(row) prod(pmax(row, 1e-6))^(1 / length(row)))
    }
    
    compute_single_y_desirability <- function(yn, kappa) {
      defY <- def2[def2$Parameter == yn, , drop = FALSE]
      purp <- if (nrow(defY) > 0 && !is.na(defY$Purpose[1])) as.character(defY$Purpose[1]) else ""
      
      score_y <- ucb_score(all_mu[[yn]], all_sd[[yn]], purp, kappa)
      lo <- min(score_y, na.rm = TRUE)
      hi <- max(score_y, na.rm = TRUE)
      
      if (hi > lo) {
        pmax(0, pmin(1, (score_y - lo) / (hi - lo)))
      } else {
        rep(0.5, length(score_y))
      }
    }
    
    base_df <- grid_df[, Xnames, drop = FALSE]
    for (yn in names(all_mu)) {
      base_df[[paste0("Pred.", yn)]] <- all_mu[[yn]]
      base_df[[paste0("SD.", yn)]]   <- all_sd[[yn]]
    }
    
    make_scope_df <- function(scope_label, desirability, n_top, mode_key, target_y_key) {
      tmp <- base_df
      tmp$Desirability <- desirability
      tmp$.mode_key    <- mode_key
      tmp$.target_key  <- target_y_key
      tmp$Scope        <- scope_label

      tmp <- tmp[order(tmp$Desirability, decreasing = TRUE), , drop = FALSE]
      tmp <- head(tmp, n_top)
      tmp$RankInScope <- as.integer(seq_len(nrow(tmp)))
      tmp
    }

    result_list <- list()

    # ── Per-Y Optimize: 2 candidates each ────────────────
    for (yn in names(all_mu)) {
      result_list[[paste0("opt_", yn)]] <- make_scope_df(
        scope_label = paste("Optimize", yn),
        desirability = compute_single_y_desirability(yn, 0.0),
        n_top = 2,
        mode_key = "Optimize",
        target_y_key = yn
      )
    }

    # ── Optimize All: desirability geometric mean ─────────
    result_list[["opt_all"]] <- make_scope_df(
      scope_label = "Optimize All",
      desirability = compute_D(0.0),
      n_top = 3,
      mode_key = "Optimize",
      target_y_key = "All"
    )

    # ── Per-Y Explore: 2 candidates each ─────────────────
    for (yn in names(all_mu)) {
      result_list[[paste0("exp_", yn)]] <- make_scope_df(
        scope_label = paste("Explore", yn),
        desirability = compute_single_y_desirability(yn, 2.0),
        n_top = 2,
        mode_key = "Explore",
        target_y_key = yn
      )
    }

    combined <- do.call(rbind, result_list)

    # 同一スコープ内での重複除去
    key_in_scope <- do.call(
      paste,
      c(combined[c("Scope", Xnames)], sep = "\r")
    )
    combined <- combined[!duplicated(key_in_scope), , drop = FALSE]

    # ソート順: Optimize Y > Optimize All > Explore Y
    scope_levels <- c(
      paste("Optimize", names(all_mu)),
      "Optimize All",
      paste("Explore", names(all_mu))
    )
    combined$Scope <- factor(combined$Scope, levels = scope_levels)
    combined$.mode_key   <- factor(combined$.mode_key,   levels = c("Optimize", "Explore"))
    combined$.target_key <- factor(combined$.target_key, levels = c(names(all_mu), "All"))

    combined <- combined[
      order(combined$.mode_key, combined$.target_key, combined$RankInScope),
      , drop = FALSE
    ]

    # 内部キー列を削除
    combined$.mode_key   <- NULL
    combined$.target_key <- NULL

    rownames(combined) <- NULL
    combined <- cbind(Candidate = paste0("cand", seq_len(nrow(combined))), combined)

    num_cols <- names(combined)[sapply(combined, is.numeric)]
    for (nm in setdiff(num_cols, "RankInScope")) {
      combined[[nm]] <- round(combined[[nm]], 4)
    }
    combined$RankInScope <- as.integer(combined$RankInScope)

    names(combined)[names(combined) == "RankInScope"] <- "Rank"
    names(combined)[names(combined) == "Desirability"] <- "Score"

    front_cols <- c("Candidate", "Scope", "Rank", "Score")
    other_cols <- setdiff(names(combined), front_cols)
    combined <- combined[, c(front_cols, other_cols), drop = FALSE]
    
    rv$cand <- combined
  })

  output$tbl_candidates <- renderTable({
    req(rv$cand)

    df <- rv$cand
    front_cols <- c("Candidate", "Scope", "Rank", "Score")
    x_cols     <- rv$X_names
    pred_cols  <- grep("^Pred\\.", names(df), value = TRUE)
    sd_cols    <- grep("^SD\\.", names(df), value = TRUE)

    show_cols <- c(front_cols, x_cols, pred_cols, sd_cols)
    show_cols <- show_cols[show_cols %in% names(df)]

    head(df[, show_cols, drop = FALSE], 60)
  }, striped = FALSE, bordered = TRUE, hover = TRUE)

})
