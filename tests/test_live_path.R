# Live REDCap code path with REDCapR stubbed (no server needed)
for (f in c("redcap_logic", "pipeline", "synthetic")) source(file.path("R", paste0(f, ".R")))
md_csv <- read_cfg("config/metadata.csv"); md <- standardise_metadata(md_csv); fdl <- read_form_logic(); rv <- read_report_variables()
start <- as.Date("2026-10-01"); end <- as.Date("2026-10-31")
full <- get_source_data("synthetic", prior_period(start, end)[1], end)$records   # same data the synthetic report uses
seen <- new.env()
stub_read <- function(redcap_uri, token, fields = NULL, records = NULL, filter_logic = "", ...) {
  if (nzchar(filter_logic)) {
    seen$filter <- filter_logic
    keep <- eval_redcap_logic(filter_logic, full, default_missing_codes)     # the server's own rule
    return(list(success = TRUE, data = tibble(record_id = full$record_id[keep])))
  }
  seen$fields <- fields; seen$records <- records
  list(success = TRUE, data = full[full$record_id %in% records, intersect(names(full), c("record_id", names(full)[sub("___.*$", "", names(full)) %in% fields])), drop = FALSE])
}
ns <- asNamespace("REDCapR")
for (f in c("redcap_read", "redcap_metadata_read", "redcap_project_info_read")) unlockBinding(f, ns)
assign("redcap_read", stub_read, ns)
assign("redcap_metadata_read", function(...) list(data = md_csv), ns)
assign("redcap_project_info_read", function(...) list(data = tibble(missing_data_codes = "NI, No information | INV, Invalid | UNK, Unknown | OTH, Other | NA, Not applicable | ND, Not Done | QI, Insufficient quantity")), ns)
Sys.setenv(REDCAP_URI = "https://example/api/", REDCAP_TOKEN = "x")
live <- load_report_data("redcap", start, end, hospital = "91")
syn  <- load_report_data("synthetic", start, end, hospital = "91")
cat("filter:", seen$filter, "\n")
cat("fields requested:", length(seen$fields), " records requested:", length(seen$records), " mothers in report:", live$n_mothers, "\n")
stopifnot(live$n_mothers == syn$n_mothers, identical(live$table$n_documented, syn$table$n_documented),
          live$n_mothers_prior == syn$n_mothers_prior,
          !any(c("mother_name", "mother_mobile", "id_no") %in% seen$fields))
cat("LIVE PATH OK: same table as the synthetic run; no names/phones pulled\n")

# boundary: a data-entry time late on the last day must be inside the window
b <- data.frame(admission_date = c("NI", "NI", "2026-10-31", "2026-11-01"),
                datetime_entry = c("2026-10-31 14:00:00", "2026-11-01 00:30:00", "", ""), hosp_id = "91")
stopifnot(identical(eval_redcap_logic(period_filter_logic(start, end, "91"), b, default_missing_codes), c(TRUE, FALSE, TRUE, FALSE)))
cat("BOUNDARY OK\n")
