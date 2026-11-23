for (f in c("redcap_logic", "pipeline", "synthetic")) source(file.path("R", paste0(f, ".R")))
fdl <- read_form_logic()
cat("disabled forms:", paste(fdl$disabled, collapse = ", "), "\n")
cat("labour monitoring logic:", fdl$logic[["labour_and_delivery_monitoring"]], "\n")
stopifnot(setequal(fdl$disabled, c("delivery_details", "post_delivery", "newborn_details")))

start <- as.Date("2026-10-01"); end <- as.Date("2026-10-31")
x <- load_report_data("synthetic", start, end, hospital = "91")
cat("hospital:", x$hospital, " mothers:", x$n_mothers, " weeks:", length(x$weeks), "\n")
print(x$mothers_by_week)

# independent check of 3 rows straight from the export
md <- standardise_metadata(read_cfg("config/metadata.csv")); rv <- x$rv
pr <- prior_period(start, end)
rec <- get_source_data("synthetic", pr[1], end)$records   # exactly the data the report uses
td <- function(v) as.Date(substr(v, 1, 10), format = "%Y-%m-%d")
a <- coalesce(td(rec$admission_date), td(rec$datetime_entry))   # admission date, else data-entry date
cat("mothers whose admission date is a missing code:", sum(rec$admission_date %in% default_missing_codes), "\n")
rec <- rec[!is.na(a) & a >= start & a <= end & rec$hosp_id == "91", ]
ok <- function(v) !is.na(v) & v != "" & !(v %in% setdiff(default_missing_codes, "OTH"))
chk <- tibble(
  row = c(1, 5, 25),
  exp_expected   = c(nrow(rec), sum(rec$is_referral %in% "1"), sum(rec$is_fhr_heard %in% "1")),
  exp_documented = c(sum(ok(rec$mother_age)), sum(rec$is_referral %in% "1" & ok(rec$referral_type)),
                     sum(rec$is_fhr_heard %in% "1" & ok(rec$fhr_heard_per_min))))
got <- x$table |> group_by(row) |> summarise(n_expected = sum(n_expected), n_documented = sum(n_documented))
res <- left_join(chk, got, by = "row") |> mutate(match = exp_expected == n_expected & exp_documented == n_documented)
print(res); stopifnot(all(res$match))
# disabled-form rows have nothing expected
dis <- x$rv$row[vapply(x$rv$fields_list, function(fs) any(md$form_name[match(fs, md$field_name)] %in% fdl$disabled), TRUE)]
cat("disabled rows:", length(dis), "\n"); stopifnot(length(dis) == 9, all(x$table$n_expected[x$table$row %in% dis] == 0))
# OTH counts as documented, ND does not
t1 <- data.frame(a = c("OTH", "ND", "3", NA)); r1 <- data.frame(field_type = "text", choices = "")
stopifnot(identical(is_documented(t1, "a", r1, default_missing_codes), c(TRUE, FALSE, TRUE, FALSE)))
cat("PIPELINE OK\n")

# report cell text must match each row's own percentage
is_pdf <- FALSE; params <- list(good = .9, caution = .7)
src <- readLines("doc_table.qmd"); i0 <- grep("^col_good <-", src); i1 <- grep("^chip <- function", src) - 1
eval(parse(text = src[i0:i1]))
out <- cell(c(107/171, 134/171, NA), c(107, 134, 0), c(171, 171, 0))
stopifnot(grepl("62%", out[1]), grepl("78%", out[2]), grepl("–", out[3]))
cat("CELL TEXT OK\n")

# takeaways: numbers agree with the table; network ranking ordered; disabled count
source("R/takeaways.R")
x <- load_report_data("synthetic", start, end, "91")
tk <- build_takeaways(x)
tot <- x$table |> filter(!row %in% unique(x$doc$row[x$doc$disabled]))
stopifnot(grepl(format(sum(tot$n_documented), big.mark = ","), tk[1]), grepl(format(sum(tot$n_expected), big.mark = ","), tk[1]))
stopifnot(any(grepl("^\\*\\*9 of 41 report variables cannot be documented", tk)))
xn <- load_report_data("synthetic", start, end, NULL)
tn <- build_takeaways(xn)
site <- period_summary(xn$doc, xn$rv, by_hosp = TRUE) |> filter(!is.na(ne), ne > 0, hosp %in% names(xn$hosp_labels)) |>
  group_by(hosp) |> summarise(p = sum(nd) / sum(ne)) |> arrange(desc(p))
best <- read_cfg("config/hospitals.csv")$short[match(site$hosp[1], read_cfg("config/hospitals.csv")$hosp_id)]
stopifnot(any(grepl(paste0("highest ", best, " \\("), tn)))
nohosp <- xn$doc |> filter(!hosp %in% names(xn$hosp_labels)) |> distinct(record_id) |> nrow()
stopifnot(any(grepl(paste0("^\\*\\*", nohosp, " mothers have no hospital recorded"), tn)))
cat("TAKEAWAYS OK\n")
