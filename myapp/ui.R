library(shiny)

shinyUI(
  fluidPage(
    title = "AutoXP3",
    tags$head(
      tags$style(HTML("
    /* ─── Dark theme (default) ─── */
    :root{
      --bg: #0b0f16;
      --panel: #0f1623;
      --card: #111b2b;
      --text: #e9eef7;
      --muted: rgba(233,238,247,0.70);
      --border: rgba(255,255,255,0.10);
      --accent: #4ea1ff;
      --accent2: #7dd3fc;
      --dangerBg: #3b1218;
      --dangerBorder: #a33;
      --dangerText: #ffd6d6;
    }

    /* ─── Light theme overrides ─── */
    body.light-theme {
      --bg: #f0f4f8;
      --panel: #ffffff;
      --card: #f8fafc;
      --text: #1e293b;
      --muted: rgba(30,41,59,0.60);
      --border: rgba(0,0,0,0.12);
      --accent: #2563eb;
      --accent2: #1d4ed8;
      --dangerBg: #fef2f2;
      --dangerBorder: #fca5a5;
      --dangerText: #991b1b;
    }
    body.light-theme { background: var(--bg) !important; color: var(--text) !important; }
    body.light-theme .main { box-shadow: 0 2px 2px rgba(0,0,0,0.08); }
    body.light-theme .table { background: #ffffff !important; color: #1e293b !important; }
    body.light-theme .table > thead > tr > th { background: #f1f5f9 !important; color: #1e293b !important; }
    body.light-theme .table > tbody > tr > td { color: #1e293b !important; border-top-color: rgba(0,0,0,0.07) !important; }
    body.light-theme .table > tbody > tr:hover { background: rgba(0,0,0,0.03) !important; }
    body.light-theme .selectize-input { background: #ffffff !important; color: #1e293b !important; border-color: rgba(0,0,0,0.18) !important; }
    body.light-theme .form-control { background: #ffffff !important; color: #1e293b !important; border-color: rgba(0,0,0,0.18) !important; }
    body.light-theme .control-label { color: rgba(30,41,59,0.7) !important; }
    body.light-theme pre, body.light-theme code { color: #1e293b !important; background: #f1f5f9 !important; border-color: rgba(0,0,0,0.12) !important; }
    body.light-theme .btn { color: #1e293b !important; background: rgba(0,0,0,0.05) !important; border-color: rgba(0,0,0,0.15) !important; }
    body.light-theme .btn-primary { background: linear-gradient(180deg,#3b82f6,#2563eb) !important; color:#ffffff !important; border-color:#2563eb !important; }
    body.light-theme .nav-tabs > li > a { color: rgba(30,41,59,0.55) !important; }
    body.light-theme .nav-tabs > li.active > a,
    body.light-theme .nav-tabs > li.active > a:focus { color: #1e293b !important; background: rgba(0,0,0,0.04) !important; border-color: rgba(0,0,0,0.12) !important; }

    /* ─── Theme toggle button ─── */
    .theme-toggle-btn {
      width: auto;
      background: transparent;
      border: none;
      padding: 4px 6px;
      cursor: pointer;
      font-size: 14px;
      color: var(--muted);
      opacity: 0.7;
    }
    
    .theme-toggle-btn:hover {
      opacity: 1;
      color: var(--text);
      background: transparent;
    }
    /* 右上固定 */
    .theme-toggle-wrap {
      position: fixed;
      top: 12px;
      right: 30px;
      z-index: 9999;
    }
    
    /* ボタン（かなり控えめ） */
    .theme-toggle-btn {
      background: transparent;
      border: none;
      padding: 6px 8px;
      font-size: 16px;
      color: var(--muted);
      opacity: 0.6;
      cursor: pointer;
    }
    
    .theme-toggle-btn:hover {
      opacity: 1;
      color: var(--text);
    }

    body{
      background: var(--bg);
      color: var(--text);
      overflow-x: hidden;
      font-family: system-ui, -apple-system, Segoe UI, Roboto, Helvetica, Arial, \"Noto Sans\", \"Liberation Sans\", sans-serif;
      line-height: 1.45;
      font-size: 14px;
    }

    a{ color: var(--accent2); }
    a:hover{ color: var(--accent); text-decoration: none; }

    .app-wrap{
      display:flex;
      gap:14px;
      padding:14px;
      width:100%;
      box-sizing:border-box;
    }

    .side{
      width:260px; min-width:260px; max-width:260px;
      display:flex; flex-direction:column; gap:12px;
    }

    .main{
      flex:1;
      width:100%;
      background: var(--panel);
      border:1px solid var(--border);
      border-radius:5px;
      padding:12px;
      box-shadow: 0 2px 2px rgba(0,0,0,0.35);
      box-sizing:border-box;
    }

    .cardx{
      background: var(--card);
      border: 1px solid var(--border);
      border-radius: 5px;
      padding: 12px;
      box-shadow: 0 2px 2px rgba(0,0,0,0.25);
    }

    .box-title{
      font-weight: 700;
      font-size: 13px;
      letter-spacing: 0.02em;
      color: var(--text);
      margin-bottom: 10px;
      opacity: 0.95;
    }

    .note{
      margin-top: 0px;
      font-size: 12px;
      color: var(--muted);
    }

    .row{ margin-0left:0 !important; margin-right:0 !important; }

    .form-control, .selectize-input, .selectize-dropdown, .input-group-addon{
      background: rgba(255,255,255,0.06) !important;
      color: var(--text) !important;
      border: 1px solid var(--border) !important;
      border-radius: 5px !important;
      box-shadow: none !important;
    }
    .form-control::placeholder{ color: rgba(233,238,247,0.45); }
    .control-label{ color: var(--muted); font-weight: 600; font-size: 12px; }

    .selectize-dropdown {
      background: #ffffff !important;
      color: #000000 !important;
      border-radius: 5px !important;
    }
    .selectize-dropdown .option {
      background: #ffffff !important;
      color: #000000 !important;
    }
    .selectize-dropdown .option.active {
      background: #4ea1ff !important;
      color: #ffffff !important;
    }

    .btn{
      border-radius: 5px;
      border: 1px solid var(--border);
      background: rgba(255,255,255,0.06);
      color: var(--text);
      font-weight: 700;
    }
    .btn:hover{ filter: brightness(1.08); color: var(--text); }
    .btn-primary{
      background: linear-gradient(180deg, rgba(78,161,255,0.95), rgba(78,161,255,0.70));
      border-color: rgba(78,161,255,0.40);
    }
    .btn-wide{ width:100%; }

    .nav-tabs{ border-bottom: 1px solid var(--border); }
    .nav-tabs > li > a{
      background: transparent !important;
      border: 1px solid transparent !important;
      color: var(--muted) !important;
      font-weight: 700;
      border-radius: 0;
      margin-right: 6px;
    }
    .nav-tabs > li.active > a,
    .nav-tabs > li.active > a:focus,
    .nav-tabs > li.active > a:hover{
      background: rgba(255,255,255,0.06) !important;
      border-color: var(--border) !important;
      color: var(--text) !important;
    }
    .tab-content{ padding-top: 10px; }

    .table{ color: var(--text); margin-bottom: 0; }
    .table > thead > tr > th{
      border-bottom: 1px solid var(--border);
      color: var(--text);
      font-size: 12px;
      opacity: 0.95;
      background: #162133;
      font-weight: 700;
    }
    .table > tbody > tr > td{
      border-top: 1px solid rgba(255,255,255,0.06);
      vertical-align: middle;
      font-size: 12px;
      color: rgba(233,238,247,0.92);
    }
    .table > tbody > tr:hover{ background: rgba(255,255,255,0.04); }
    .table { color: #e9eef7 !important; background: #0f1623; }

    pre, code{
      color: rgba(233,238,247,0.92);
      background: rgba(0,0,0,0.25);
      border: 1px solid rgba(255,255,255,0.08);
      border-radius: 5px;
      padding: 10px;
    }

    .fixed-plot{ height: 460px; }

    .errorbox{
      background: var(--dangerBg);
      border: 1px solid var(--dangerBorder);
      color: var(--dangerText);
    }

    .side {
      display: flex;
      flex-direction: column;
      height: 100%;
    }
    .side-footer-img {
      margin-top: auto;
      padding-top: 15px;
      text-align: center;
    }
    .side-footer-img img {
      max-width: 90%;
      opacity: 0.9;
    }
    ")),

      # ─── Theme toggle script ───
      tags$script(HTML("
        function toggleTheme() {
          var body = document.body;
          body.classList.toggle('light-theme');
        }
      "))
    ),

    div(class = "app-wrap",

      # ─── Sidebar ───
      div(class = "side",
        div(class = "cardx",
          div(
            tags$a(href = "https://github.com/long-rh/AutoXP3-shinylive/raw/main/template.xlsx",
              download = "template.xlsx", "Download Template"),
            div(class = "box-title", "File Upload")
          ),
          fileInput("file_xlsx", label = NULL, accept = c(".xlsx", ".xls")),
          uiOutput("ui_sheet"),
          uiOutput("ui_col_select"),
          uiOutput("ui_error"),
          uiOutput("ui_y_view"),
          div(br()),
          uiOutput("ui_btn_fit"),
          div(br()),
          uiOutput("ui_btn_save_result")
        ),

        div(class = "cardx",
          div(class = "box-title", "Input / Output info"),
          uiOutput("ui_info")
        ),
        

        
        div(class = "side-footer-img",
            tags$img(src = "logo.png")
            )
      ),

      # ─── Main ───
      div(class = "main",
          tags$div(
            class = "theme-toggle-wrap",
            tags$button(
              id = "themeToggleBtn",
              class = "theme-toggle-btn",
              onclick = "toggleTheme()",
              tags$span(class = "fa fa-adjust")
            )
          ),
        tabsetPanel(
          id = "tabs", type = "tabs",

          # ── 1. Data ──
          tabPanel("1. Data",
            fluidRow(
              column(12,
                div(class = "cardx",
                  div(class = "box-title", "Data"),
                  tableOutput("tbl_uploaded_data")
                )
              )
            ),
            br(),
            fluidRow(
              column(12,
                div(class = "cardx",
                  div(class = "box-title", "Definition"),
                  tableOutput("tbl_definition")
                )
              )
            ),
            br(),
            uiOutput("ui_constraints_card"),
            br(),
            uiOutput("ui_model_sheet_card")
            #br(),
            # Feature 4: Box-Cox toggle
            #uiOutput("ui_boxcox_card")
          ),

          # ── 2. Model ──
          tabPanel("2. Model",
            fluidRow(
              column(4,
                div(class = "cardx",
                  fluidRow (column(12, uiOutput("ui_y_view_model"))),
                  #br(),
                  fluidRow(
                    column(6, numericInput("hp2", HTML("Lengthscale"),  value = 0.4,  min = 1e-6, step = 0.1)),
                    column(6, numericInput("hp3", HTML("Noise"),    value = 0.05, min = 1e-6, step = 0.01))
                )),
                br(),
                fluidRow(
                  column(6, uiOutput("ui_btn_refit"))
                )
              ),
              column(8,
                div(class = "cardx fixed-plot",
                  plotOutput("plot_pred_vs_obs", height = "100%")
                )
              )
            ),
            br(),
            fluidRow(
              column(12,
                div(class = "cardx",
                  div(class = "box-title", "Fitting result information"),
                  verbatimTextOutput("fit_info")
                )
              )
            )
          ),

          # ── 3. Analyze ──
          tabPanel("3. Analyze",
            fluidRow(
              column(4,
                div(class = "cardx",
                  fluidRow (column(12, uiOutput("ui_y_view_analyze"))),
                  #br(),
                  uiOutput("ui_x12_select"),
                  div(class = "note", "Other X are fixed at Standard in Definition (or Min if missing).")
                )
              ),
              column(8,
                div(class = "cardx fixed-plot",
                  plotOutput("plot_1d", height = "100%")
                )
              )
            ),
            br(),
            fluidRow(
              column(12,
                     div(class = "cardx",
                         div(class = "box-title", "Fitting result information"),
                         verbatimTextOutput("fit_info_analyze")
                     )
              )
            )
          ),

          # ── 4. Optimize ──
          tabPanel("4. Optimize",
            fluidRow(
              column(12,
                     div(class = "cardx",
                         uiOutput("ui_btn_suggest"),
                         uiOutput("ui_optimize_status"),
                         br(),
                         tableOutput("tbl_candidates")
                     )
              )
            )
          )
        )
      )
    )
  )
)
