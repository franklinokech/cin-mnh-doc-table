# Evaluate REDCap logic in R -------------------------------------------------------
#
# Used for branching logic, form display logic and the consistency rules in
# config/consistency_rules.csv, which are written in REDCap logic syntax:
#   [field], [checkbox(code)], = <> < > <= >=, and / or, ( ),
#   datediff([d1], [d2], 'unit', true), isblankormissingcode([field]),
#   'today', 'now', left(), right(), contains(), upper(), lower(), trim()
#
# REDCap semantics reproduced here:
#   * blank compares as "" (so  [x] <> '0'  is TRUE when x is blank)
#   * = / <> compare numerically when both sides look numeric, else as text
#   * < > <= >= are numeric; a blank or non-numeric side gives FALSE
#   * datediff() of a blank / invalid date is blank, so comparisons on it are FALSE

suppressPackageStartupMessages(library(lubridate))

rcval <- function(x) structure(as.character(x), class = "rcval")

Ops.rcval <- function(e1, e2) {
  a <- as.character(unclass(e1)); b <- as.character(unclass(e2))
  a[is.na(a)] <- ""; b[is.na(b)] <- ""
  op <- .Generic
  an <- suppressWarnings(as.numeric(a)); bn <- suppressWarnings(as.numeric(b))
  if (op %in% c("==", "!=")) {
    both_num <- !is.na(an) & !is.na(bn)
    eq <- ifelse(both_num, an == bn, a == b)
    return(if (op == "==") eq else !eq)
  }
  if (op %in% c("<", ">", "<=", ">=")) {
    res <- get(op)(an, bn); res[is.na(res)] <- FALSE
    return(res)
  }
  if (op %in% c("+", "-", "*", "/")) {   # arithmetic: blank / non-numeric gives blank
    if (missing(e2)) return(rcval(if (op == "-") -an else an))
    return(rcval(get(op)(an, bn)))
  }
  stop("Unsupported operator in REDCap logic: ", op)
}
# register so dispatch works wherever these files are sourced
registerS3method("Ops", "rcval", Ops.rcval)

#' Parse REDCap date / datetime text (Y-M-D [H:M[:S]]), 'today' and 'now'
parse_redcap_datetime <- function(x) {
  x <- as.character(unclass(x))
  x[x %in% "today"] <- format(Sys.Date(), "%Y-%m-%d")
  x[x %in% "now"]   <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
  x[is.na(x) | !nzchar(trimws(x))] <- NA_character_
  suppressWarnings(parse_date_time(x, orders = c("Ymd HMS", "Ymd HM", "Ymd"), tz = "UTC", quiet = TRUE))
}

#' REDCap datediff(date1, date2, units, signed): date2 - date1 in `units`
redcap_datediff <- function(d1, d2, units = "d", signed = FALSE) {
  t1 <- parse_redcap_datetime(d1); t2 <- parse_redcap_datetime(d2)
  secs <- as.numeric(difftime(t2, t1, units = "secs"))
  div <- switch(as.character(units), y = 365.2425 * 86400, M = 30.44 * 86400, d = 86400,
                h = 3600, m = 60, s = 1, stop("Unknown datediff unit: ", units))
  out <- secs / div
  if (!(isTRUE(signed) || identical(tolower(as.character(signed)), "true"))) out <- abs(out)
  out
}

redcap_logic_to_r <- function(logic) {
  x <- gsub("[\r\n\t]+", " ", logic)
  x <- gsub("\\[([A-Za-z0-9_]+)\\(([A-Za-z0-9_-]+)\\)\\]", ".v('\\1___\\L\\2')", x, perl = TRUE)
  x <- gsub("\\[([A-Za-z0-9_]+)\\]", ".v('\\1')", x)
  x <- gsub("<>", "!=", x, fixed = TRUE)
  x <- gsub("(?<![<>!=])=(?!=)", "==", x, perl = TRUE)
  x <- gsub("\\band\\b", "&", x, ignore.case = TRUE, perl = TRUE)
  x <- gsub("\\bor\\b", "|", x, ignore.case = TRUE, perl = TRUE)
  x <- gsub("\\btrue\\b", "TRUE", x, ignore.case = TRUE, perl = TRUE)
  x <- gsub("\\bfalse\\b", "FALSE", x, ignore.case = TRUE, perl = TRUE)
  x
}

#' Fields referenced by REDCap logic (base names; checkbox suffix dropped)
logic_fields <- function(logic) {
  logic <- logic[!is.na(logic) & nzchar(logic)]
  if (!length(logic)) return(character())
  m <- regmatches(logic, gregexpr("\\[([A-Za-z0-9_]+)(\\([A-Za-z0-9_-]+\\))?\\]", logic))
  unique(gsub("^\\[|(\\(.*\\))?\\]$", "", unlist(m)))
}

#' Evaluate REDCap logic on a data frame; returns a logical vector (NA -> FALSE)
eval_redcap_logic <- function(logic, data, missing_codes = character(), warn_missing = TRUE) {
  n <- nrow(data)
  if (is.null(logic) || is.na(logic) || !nzchar(trimws(logic))) return(rep(TRUE, n))
  missing_fields <- character()
  env <- new.env(parent = baseenv())
  env$.v <- function(name) {
    if (name %in% names(data)) return(rcval(data[[name]]))
    missing_fields <<- c(missing_fields, name)
    rcval(rep(NA_character_, n))
  }
  env$datediff <- redcap_datediff
  env$isblankormissingcode <- function(x) {
    v <- as.character(unclass(x)); is.na(v) | !nzchar(trimws(v)) | v %in% missing_codes
  }
  env$ismissingcode <- function(x) as.character(unclass(x)) %in% missing_codes
  # REDCap text functions
  txt <- function(x) as.character(unclass(x))
  env$left  <- function(x, n) rcval(substr(txt(x), 1, n))
  env$right <- function(x, n) { v <- txt(x); rcval(ifelse(is.na(v), NA, substr(v, pmax(1, nchar(v) - n + 1), nchar(v)))) }
  env$contains <- function(x, s) !is.na(txt(x)) & grepl(txt(s), txt(x), fixed = TRUE)
  env$upper <- function(x) rcval(toupper(txt(x)))
  env$lower <- function(x) rcval(tolower(txt(x)))
  env$trim  <- function(x) rcval(trimws(txt(x)))
  expr <- redcap_logic_to_r(logic)
  out <- tryCatch(eval(parse(text = expr), envir = env),
                  error = function(e) stop("Could not evaluate REDCap logic: ", logic,
                                           "\n  translated: ", expr, "\n  ", conditionMessage(e), call. = FALSE))
  if (warn_missing && length(missing_fields))
    warning("Logic refers to fields not in the data (treated as blank): ",
            paste(unique(missing_fields), collapse = ", "), call. = FALSE)
  out <- as.logical(out)
  if (length(out) == 1L) out <- rep(out, n)
  out[is.na(out)] <- FALSE
  out
}
