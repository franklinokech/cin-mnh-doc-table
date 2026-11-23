#!/usr/bin/env Rscript
# Render the documentation report for every hospital plus the whole network --------
#
#   Rscript R/render_batch.R --month 2026-10
#   Rscript R/render_batch.R --month 2026-10 --hospitals 91,72
#   Rscript R/render_batch.R --start 2026-10-12 --end 2026-11-08 --no-network
#   Rscript R/render_batch.R --month 2026-10 --source synthetic --formats pdf
#
# REDCap is pulled ONCE (all hospitals, report period + previous period); each report
# reads that copy. Only hospitals with at least one mother in the period get a report.
# Output: output/<period>/<Hospital>_<period>.html|pdf, CIN-MNH_Network_<period>.*,
# and batch_log.csv. The shared copy holds record-level data and is deleted at the end.

suppressPackageStartupMessages({ library(lubridate) })
for (f in c("redcap_logic", "pipeline", "synthetic")) source(file.path("R", paste0(f, ".R")))

args <- commandArgs(trailingOnly = TRUE)
arg <- function(name, default = NULL) {
  i <- match(paste0("--", name), args)
  if (is.na(i)) default else if (i == length(args) || startsWith(args[i + 1], "--")) TRUE else args[i + 1]
}
source_mode <- arg("source", "redcap")
formats <- strsplit(arg("formats", "html,pdf"), ",")[[1]]
out_root <- arg("out", "output")
network <- !isTRUE(arg("no-network", FALSE))

if (!is.null(arg("start")) && !is.null(arg("end"))) {
  start <- as.Date(arg("start")); end <- as.Date(arg("end"))
  tag <- paste0(format(start), "_to_", format(end))
} else {
  m1 <- if (!is.null(arg("month"))) as.Date(paste0(arg("month"), "-01")) else floor_date(Sys.Date(), "month") %m-% months(1)
  start <- m1; end <- ceiling_date(m1, "month") - 1; tag <- format(m1, "%Y-%m")
}
out_dir <- file.path(out_root, tag)
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
message("Period ", format(start), " to ", format(end), " -> ", out_dir)

# ---- one pull for the whole batch ----
pr <- prior_period(start, end)
src <- get_source_data(source_mode, pr[1], end, hospital = NULL)
if (is.null(src$records) || !nrow(src$records)) stop("No records in REDCap for ", tag, call. = FALSE)
cache <- normalizePath(tempfile("cin_batch_", fileext = ".rds"), mustWork = FALSE)
saveRDS(src, cache)
on.exit(unlink(cache), add = TRUE)

# ---- which hospitals ----
hosp_cfg <- read_cfg("config/hospitals.csv")
base <- src$records
if ("redcap_repeat_instrument" %in% names(base)) base <- base[blank(base$redcap_repeat_instrument), ]
anchor <- coalesce(as.Date(substr(base$admission_date, 1, 10), format = "%Y-%m-%d"),
                   as.Date(substr(base$datetime_entry, 1, 10), format = "%Y-%m-%d"))
in_period <- !is.na(anchor) & anchor >= start & anchor <= end
counts <- table(base$hosp_id[in_period])
wanted <- if (!is.null(arg("hospitals"))) strsplit(arg("hospitals"), ",")[[1]] else hosp_cfg$hosp_id
hospitals <- wanted[wanted %in% names(counts)]
skipped <- setdiff(wanted, hospitals)
if (length(skipped)) message("No mothers in the period, skipped: ", paste(hosp_cfg$short[match(skipped, hosp_cfg$hosp_id)], collapse = ", "))

# ---- render ----
render_one <- function(hosp_param, file_stub) {
  vapply(formats, function(fmt) {
    to <- if (fmt == "pdf") "typst" else fmt
    file <- paste0(file_stub, ".", fmt)
    p <- c("-P", paste0("hospital:", hosp_param), "-P", paste0("source:", source_mode), "-P", paste0("cache:", cache),
           "-P", paste0("start_date:", format(start)), "-P", paste0("end_date:", format(end)))
    status <- system2("quarto", c("render", "doc_table.qmd", "--to", to, "--output", file, p), stdout = FALSE, stderr = FALSE)
    if (status != 0 || !file.exists(file)) return(NA_character_)
    dest <- file.path(out_dir, file)
    file.rename(file, dest)
    dest
  }, "")
}

jobs <- c(setNames(hospitals, hosp_cfg$short[match(hospitals, hosp_cfg$hosp_id)]), if (network) c(Network = "all"))
log <- do.call(rbind, lapply(names(jobs), function(nm) {
  stub <- if (jobs[[nm]] == "all") paste0("CIN-MNH_Network_", tag) else paste0(gsub("[^A-Za-z0-9]+", "_", nm), "_", tag)
  message("Rendering ", nm, " ...")
  files <- render_one(jobs[[nm]], stub)
  data.frame(report = nm, hosp_id = jobs[[nm]],
             mothers = if (jobs[[nm]] == "all") sum(in_period) else as.integer(counts[[jobs[[nm]]]]),
             files = paste(basename(na.omit(files)), collapse = "; "),
             status = if (all(!is.na(files))) "ok" else "FAILED")
}))
write.csv(log, file.path(out_dir, "batch_log.csv"), row.names = FALSE)
print(log, row.names = FALSE)
if (any(log$status != "ok")) quit(status = 1)
