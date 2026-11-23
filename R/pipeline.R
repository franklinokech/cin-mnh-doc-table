# CIN-MNH weekly documentation table: data pull and computation --------------------

suppressPackageStartupMessages({
  library(dplyr); library(tidyr); library(purrr); library(stringr); library(readr); library(lubridate)
})

# Project "Codes for Missing Data" (codebook p.1)
default_missing_codes <- c("NI", "INV", "UNK", "OTH", "NA", "ND", "QI")
# Codes that are real answers and so count as documented ("Other (specify)")
documented_codes <- c("OTH")

read_cfg <- function(path) read_csv(path, col_types = cols(.default = col_character()), na = character())

standardise_metadata <- function(md) {
  nm <- c("Variable / Field Name" = "field_name", "Form Name" = "form_name", "Field Type" = "field_type",
          "Field Label" = "field_label", "Choices, Calculations, OR Slider Labels" = "choices",
          "select_choices_or_calculations" = "choices",
          "Text Validation Type OR Show Slider Number" = "validation",
          "text_validation_type_or_show_slider_number" = "validation",
          "Branching Logic (Show field only if...)" = "branching_logic",
          "Field Annotation" = "field_annotation")
  hit <- intersect(names(nm), names(md))
  names(md)[match(hit, names(md))] <- nm[hit]
  md |> mutate(across(everything(), ~ coalesce(as.character(.x), "")))
}

parse_choices <- function(x) {
  if (is.na(x) || !nzchar(x)) return(character())
  trimws(sub(",.*$", "", strsplit(x, "\\|")[[1]]))
}
choice_labels <- function(x) {
  if (is.na(x) || !nzchar(x)) return(character())
  p <- strsplit(x, "\\|")[[1]]
  setNames(trimws(sub("^[^,]*,", "", p)), trimws(sub(",.*$", "", p)))
}

#' Form display logic. REDCap enables a form when ANY of its conditions is true,
#' so rows for the same form are combined with "or". A form whose conditions are all
#' constant-false (e.g. 1=2) is "disabled".
read_form_logic <- function(path = "config/form_display_logic.csv") {
  fdl <- read_cfg(path) |> filter(tolower(apply_to_data_entry) == "y")
  combined <- fdl |> group_by(form_name) |>
    summarise(logic = paste0("(", control_condition, ")", collapse = " or "),
              disabled = all(vapply(control_condition, function(l)
                !length(logic_fields(l)) && !isTRUE(eval_redcap_logic(l, data.frame(x = 1))[1]), logical(1))),
              .groups = "drop")
  list(logic = setNames(combined$logic, combined$form_name),
       disabled = combined$form_name[combined$disabled])
}

read_report_variables <- function(path = "config/report_variables.csv") {
  read_cfg(path) |> mutate(row = row_number(), fields_list = strsplit(fields, "\\|"))
}

#' Fields to pull: report fields + everything their logic needs + anchors
fields_needed <- function(rv, md, fdl) {
  bl <- setNames(md$branching_logic, md$field_name); form_of <- setNames(md$form_name, md$field_name)
  need <- unique(c(md$field_name[1], "hosp_id", "admission_date", "datetime_entry", unlist(rv$fields_list),
                   logic_fields(rv$expected_when)))
  repeat {
    refs <- c(logic_fields(bl[need]), logic_fields(fdl$logic[names(fdl$logic) %in% form_of[need]]))
    new <- setdiff(intersect(refs, md$field_name), need)
    if (!length(new)) break
    need <- c(need, new)
  }
  intersect(md$field_name, need)   # dictionary order
}

# ---- REDCap ----------------------------------------------------------------------

redcap_credentials <- function() {
  uri <- Sys.getenv("REDCAP_URI"); token <- Sys.getenv("REDCAP_TOKEN")
  if (!nzchar(uri) || !nzchar(token)) stop("Set REDCAP_URI and REDCAP_TOKEN in .Renviron (see .Renviron.example).", call. = FALSE)
  list(uri = uri, token = token)
}

redcap_read_chr <- function(cred, ...) {
  res <- REDCapR::redcap_read(redcap_uri = cred$uri, token = cred$token, raw_or_label = "raw",
                              col_types = readr::cols(.default = readr::col_character()),
                              guess_type = FALSE, verbose = FALSE, ...)
  if (!isTRUE(res$success)) stop("REDCap export failed: ", res$outcome_message, call. = FALSE)
  res$data
}

fetch_missing_codes <- function(cred) {
  info <- tryCatch(REDCapR::redcap_project_info_read(redcap_uri = cred$uri, token = cred$token, verbose = FALSE)$data,
                   error = function(e) NULL)
  raw <- if (!is.null(info) && "missing_data_codes" %in% names(info)) info$missing_data_codes[1] else NA
  if (is.na(raw) || !nzchar(raw)) default_missing_codes else parse_choices(raw)
}

#' Server-side selection: hospital and admission date in the period (data entry date
#' when the admission date is blank / a missing code). The same rule is re-applied in R.
period_filter_logic <- function(start, end, hospital = NULL) {
  # upper bound = midnight after the last day, so a date-time on the last day is included
  s <- format(start); e1 <- format(end + 1)
  in_win <- function(f) sprintf("datediff('%s', [%s], 'd', true) >= 0 and datediff([%s], '%s', 'd', true) > 0", s, f, f, e1)
  logic <- sprintf("((%s) or (isblankormissingcode([admission_date]) and %s))", in_win("admission_date"), in_win("datetime_entry"))
  if (!is.null(hospital)) logic <- sprintf("[hosp_id] = '%s' and %s", hospital, logic)
  logic
}

pull_records <- function(cred, md, fields, start, end, hospital) {
  ids <- unique(redcap_read_chr(cred, fields = md$field_name[1],
                                filter_logic = period_filter_logic(start, end, hospital))[[md$field_name[1]]])
  if (!length(ids)) return(NULL)
  redcap_read_chr(cred, fields = fields, records = ids, batch_size = 500L)
}

# ---- Computation -----------------------------------------------------------------

blank <- function(v) is.na(v) | !nzchar(trimws(v))

#' TRUE where a field holds a documented answer: a real value, or "OTH"
is_documented <- function(d, f, md_row, missing_codes) {
  undocumented <- setdiff(missing_codes, documented_codes)
  if (md_row$field_type == "checkbox") {
    codes <- tolower(c(parse_choices(md_row$choices), documented_codes))
    cols <- intersect(paste0(f, "___", codes), names(d))
    if (!length(cols)) return(rep(FALSE, nrow(d)))
    m <- as.matrix(d[cols]) == "1"; m[is.na(m)] <- FALSE
    return(rowSums(m) > 0)
  }
  v <- if (f %in% names(d)) d[[f]] else rep(NA_character_, nrow(d))
  !blank(v) & !(v %in% undocumented)
}

#' One row per (mother, report variable): expected? documented?
compute_documentation <- function(records, md, rv, fdl, missing_codes, start, end, hospital = NULL) {
  id <- md$field_name[1]
  base <- if ("redcap_repeat_instrument" %in% names(records))
    records[blank(records$redcap_repeat_instrument), , drop = FALSE] else records
  to_date <- function(x) as.Date(substr(x, 1, 10), format = "%Y-%m-%d")
  base$.anchor <- coalesce(to_date(base$admission_date), to_date(base$datetime_entry))
  keep <- !is.na(base$.anchor) & base$.anchor >= start & base$.anchor <= end
  if (!is.null(hospital)) keep <- keep & base$hosp_id %in% hospital
  base <- base[keep, , drop = FALSE]
  base$.week <- floor_date(base$.anchor, "week", week_start = 1)

  mdi <- md |> filter(field_name %in% unlist(rv$fields_list))
  rep_forms <- if ("redcap_repeat_instrument" %in% names(records)) setdiff(unique(records$redcap_repeat_instrument), c(NA, "")) else character()
  bad <- intersect(mdi$form_name, rep_forms)
  if (length(bad)) warning("Report variables on repeating forms are not supported: ", paste(bad, collapse = ", "), call. = FALSE)

  map_dfr(seq_len(nrow(rv)), function(i) {
    fs <- rv$fields_list[[i]]
    forms <- unique(mdi$form_name[match(fs, mdi$field_name)])
    disabled <- any(forms %in% fdl$disabled)
    expected <- eval_redcap_logic(rv$expected_when[i], base, missing_codes)
    documented <- rep(TRUE, nrow(base))
    for (f in fs) {
      r <- mdi[mdi$field_name == f, ]
      fl <- if (r$form_name %in% names(fdl$logic)) fdl$logic[[r$form_name]] else ""
      expected <- expected & eval_redcap_logic(fl, base, missing_codes, warn_missing = FALSE) &
                  eval_redcap_logic(r$branching_logic, base, missing_codes, warn_missing = FALSE)
      documented <- documented & is_documented(base, f, r, missing_codes)
    }
    tibble(row = rv$row[i], record_id = base[[id]], hosp = base$hosp_id, week = base$.week,
           expected = expected, documented = documented, disabled = disabled)
  })
}

#' Weekly table (long): expected, documented, % per report row and week
weekly_table <- function(doc, rv, weeks) {
  doc |> filter(expected) |>
    group_by(row, week) |> summarise(n_expected = n(), n_documented = sum(documented), .groups = "drop") |>
    complete(row = rv$row, week = weeks, fill = list(n_expected = 0L, n_documented = 0L)) |>
    mutate(pct = ifelse(n_expected > 0, n_documented / n_expected, NA_real_))
}

#' Records for a window, for one hospital or all. Pulled from REDCap, generated
#' (synthetic), or read from a cache written by R/render_batch.R so a batch of
#' hospital reports needs only one API pull.
get_source_data <- function(source, start, end, hospital = NULL, cache = "") {
  if (nzchar(cache) && file.exists(cache)) return(readRDS(cache))
  rv <- read_report_variables(); fdl <- read_form_logic()
  if (source == "redcap") {
    cred <- redcap_credentials()
    md <- standardise_metadata(REDCapR::redcap_metadata_read(redcap_uri = cred$uri, token = cred$token, verbose = FALSE)$data)
    missing_codes <- fetch_missing_codes(cred)
    records <- pull_records(cred, md, fields_needed(rv, md, fdl), start, end, hospital)
  } else {
    md <- standardise_metadata(read_cfg("config/metadata.csv"))
    missing_codes <- default_missing_codes
    records <- simulate_records(md, fields_needed(rv, md, fdl), fdl, missing_codes, start - 35, end)
  }
  list(records = records, md = md, missing_codes = missing_codes, source = source, pulled_at = Sys.time())
}

#' Previous period of the same kind: previous calendar month for a whole month,
#' otherwise the same number of days immediately before.
prior_period <- function(start, end) {
  whole_month <- day(start) == 1 && end == ceiling_date(start, "month") - 1
  if (whole_month) { ps <- start %m-% months(1); return(c(ps, start - 1)) }
  len <- as.numeric(end - start) + 1
  c(start - len, start - 1)
}

load_report_data <- function(source = c("redcap", "synthetic"), start, end, hospital = NULL, cache = "") {
  source <- match.arg(source)
  rv <- read_report_variables(); fdl <- read_form_logic()
  pr <- prior_period(start, end)
  src <- get_source_data(source, pr[1], end, hospital, cache)
  if (is.null(src$records) || !nrow(src$records)) stop("No records for this hospital and period.", call. = FALSE)
  md <- src$md
  doc   <- compute_documentation(src$records, md, rv, fdl, src$missing_codes, start, end, hospital)
  prior <- compute_documentation(src$records, md, rv, fdl, src$missing_codes, pr[1], pr[2], hospital)
  weeks <- seq(floor_date(start, "week", week_start = 1), end, by = "week")
  hosp_lab <- choice_labels(md$choices[md$field_name == "hosp_id"])
  list(doc = doc, prior_doc = prior, table = weekly_table(doc, rv, weeks), rv = rv, fdl = fdl, weeks = weeks,
       n_mothers = n_distinct(doc$record_id), n_mothers_prior = n_distinct(prior$record_id),
       mothers_by_week = doc |> distinct(record_id, week) |> count(week, name = "n") |>
         complete(week = weeks, fill = list(n = 0L)),
       network = is.null(hospital), hosp_labels = hosp_lab,
       hospital = if (is.null(hospital)) "CIN-MNH Network (all hospitals)" else unname(hosp_lab[hospital]) %||% hospital,
       source = src$source, start = start, end = end, prior_start = pr[1], prior_end = pr[2],
       pulled_at = src$pulled_at, missing_codes = src$missing_codes)
}

#' Mothers per week, with how many report days each week covers and a "low" flag.
#' Weeks are compared by daily rate, not raw count, so a first/last week clipped to
#' the period (e.g. Thu 1 Oct - Sun 4 Oct) is not flagged just for being short.
#' Low = no mothers, or under `low_ratio` of the typical (median full-week) rate,
#' once the typical week has at least `min_typical` mothers.
#' Used by both the admissions chart and the takeaways, so they always agree.
weekly_volume <- function(x, low_ratio = 0.5, min_typical = 5) {
  mb <- x$mothers_by_week
  days <- as.integer(pmin(mb$week + 6, x$end) - pmax(mb$week, x$start)) + 1L
  full <- days == 7
  rate <- mb$n / days
  typical <- 7 * median(rate[if (any(full)) full else TRUE])   # mothers in a typical full week
  expected <- typical * days / 7                               # scaled to the days each week covers
  low <- mb$n == 0 | (typical >= min_typical & mb$n < low_ratio * expected)
  tibble(week = mb$week, n = mb$n, days = days, partial = !full,
         typical = typical, expected = expected, low = low)
}

#' Period summary per report row (optionally per hospital)
period_summary <- function(doc, rv, by_hosp = FALSE) {
  g <- if (by_hosp) c("row", "hosp") else "row"
  doc |> filter(expected) |> group_by(across(all_of(g))) |>
    summarise(ne = n(), nd = sum(documented), .groups = "drop") |>
    mutate(pct = nd / ne) |> right_join(rv |> select(row, section, label), by = "row")
}

`%||%` <- function(a, b) if (is.null(a) || !length(a) || is.na(a)) b else a
