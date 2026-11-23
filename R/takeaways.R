# Key takeaways for action -------------------------------------------------------------
#
# Rule-based bullets from the report data (same data -> same wording):
#   overall level and change vs the previous period, variables needing immediate
#   action, large drops and improvements, the weakest sections with their action
#   (config/section_actions.csv), data-entry volume warnings and disabled forms.
#   Network mode adds a site ranking and gaps shared by most sites.
# A variable is only named when at least `min_n` mothers were expected to have it.

period_name <- function(start, end) {
  if (day(start) == 1 && end == ceiling_date(start, "month") - 1) format(start, "%B %Y")
  else paste(format(start, "%d %b"), "–", format(end, "%d %b %Y"))
}
pc  <- function(p) paste0(floor(p * 100), "%")
pp  <- function(d) paste0(ifelse(d < 0, "\u2212", "+"), sprintf("%.0f", abs(d)), " pp")   # true minus sign
and_list <- function(v) if (length(v) <= 1) v else paste(paste(head(v, -1), collapse = ", "), "and", tail(v, 1))
form_title <- function(f) tools::toTitleCase(gsub("_", " ", f))
fmt_n <- function(n) format(n, big.mark = ",")
list_vars <- function(d, extra = "") paste0(d$label, " (", pc(d$pct), extra, ")", collapse = "; ")

build_takeaways <- function(x, good = .90, caution = .70, min_n = 10, change_pp = 10, max_items = 3,
                            actions_path = "config/section_actions.csv", hospitals_path = "config/hospitals.csv") {
  out <- character()
  rv <- x$rv
  actions <- if (file.exists(actions_path)) setNames(read_cfg(actions_path)$action, read_cfg(actions_path)$section) else character()
  cur <- period_summary(x$doc, rv) |> filter(!is.na(ne), ne > 0)
  pri <- period_summary(x$prior_doc, rv) |> filter(!is.na(ne), ne > 0)
  prior_name <- period_name(x$prior_start, x$prior_end)

  if (!nrow(cur)) return("No mothers were recorded in REDCap for this period, so documentation cannot be assessed. **Action:** check that data entry is up to date.")

  # 1. overall
  o_cur <- sum(cur$nd) / sum(cur$ne)
  o_pri <- if (nrow(pri)) sum(pri$nd) / sum(pri$ne) else NA
  level <- if (o_cur >= good) "optimal" else if (o_cur >= caution) "needs attention" else "requires immediate action"
  cmp <- if (!is.na(o_pri)) {
    d <- (o_cur - o_pri) * 100
    paste0(", ", if (abs(d) < 1) "about the same as" else if (d > 0) "up from" else "down from", " ", pc(o_pri), " in ", prior_name,
           if (abs(d) >= 1) paste0(" (", pp(d), ")") else "")
  } else ""
  out <- c(out, paste0("**Overall, ", pc(o_cur), " of expected entries were documented** (", fmt_n(sum(cur$nd)), " of ", fmt_n(sum(cur$ne)),
                       " across ", fmt_n(x$n_mothers), " mothers)", cmp, ". This ", level, "."))

  # 2. variables needing immediate action
  crit <- cur |> filter(ne >= min_n, pct < caution) |> arrange(pct)
  if (nrow(crit)) {
    more <- if (nrow(crit) > max_items) paste0(", and ", nrow(crit) - max_items, " more in the table") else ""
    out <- c(out, paste0("**Requires immediate action (below ", pc(caution), "):** ", list_vars(head(crit, max_items)), more, "."))
  } else if (o_cur >= good) {
    out <- c(out, paste0("**No variable is below ", pc(caution), ".** Keep up the current documentation practice."))
  }

  # 3. changes vs previous period
  if (nrow(pri)) {
    ch <- cur |> filter(ne >= min_n) |> inner_join(pri |> filter(ne >= min_n) |> select(row, pct_prior = pct), by = "row") |>
      mutate(d = (pct - pct_prior) * 100)
    drop <- ch |> filter(d <= -change_pp) |> arrange(d)
    rise <- ch |> filter(d >= change_pp) |> arrange(desc(d))
    fmt_ch <- function(z) paste0(z$label, " ", pc(z$pct_prior), " → ", pc(z$pct), " (", pp(z$d), ")", collapse = "; ")
    if (nrow(drop)) out <- c(out, paste0("**Dropped since ", prior_name, ":** ", fmt_ch(head(drop, max_items)), ". Find out what changed (staff, forms, data entry)."))
    if (nrow(rise)) out <- c(out, paste0("**Improved since ", prior_name, ":** ", fmt_ch(head(rise, max_items)), ". Recognise the team and keep the practice going."))
  }

  # 4. weakest sections, with their action
  sec <- cur |> group_by(section) |> summarise(pct = sum(nd) / sum(ne), ne = sum(ne), n_vars = n(), .groups = "drop") |>
    filter(pct < good, n_vars >= 2) |> arrange(pct) |> head(2)   # a 1-variable section would repeat the variable bullet
  for (i in seq_len(nrow(sec))) {
    a <- if (sec$section[i] %in% names(actions)) paste0(" **Action:** ", actions[[sec$section[i]]]) else ""
    out <- c(out, paste0("**", if (i == 1) "Weakest section" else "Also weak", ": ", sub("^[0-9]+\\. ", "", sec$section[i]),
                         " (", pc(sec$pct[i]), ").**", a))
  }

  # 5. data-entry volume
  mb <- x$mothers_by_week
  if (nrow(mb) >= 3) {
    typical <- median(head(mb$n, -1))
    last <- tail(mb$n, 1)
    if (typical >= 5 && last < 0.5 * typical)
      out <- c(out, paste0("**Fewer records in the latest week** (", last, " vs a typical ", typical,
                           "): data entry may be behind, so the latest figures may still change. **Action:** clear the data-entry backlog."))
    empty <- mb$week[mb$n == 0]
    if (length(empty)) out <- c(out, paste0("**No mothers recorded in ", paste0("W", isoweek(empty), collapse = ", "),
                                            ".** **Action:** check that all files for those weeks have been entered."))
  }

  # 6. network: ranking and shared gaps
  if (isTRUE(x$network)) {
    hosp <- if (file.exists(hospitals_path)) read_cfg(hospitals_path) else tibble(hosp_id = character(), short = character())
    short <- function(h) ifelse(h %in% hosp$hosp_id, hosp$short[match(h, hosp$hosp_id)], h)
    bh_all <- period_summary(x$doc, rv, by_hosp = TRUE) |> filter(!is.na(ne), ne > 0)
    known <- names(x$hosp_labels)
    bh <- bh_all |> filter(hosp %in% known)
    no_hosp <- x$doc |> filter(!hosp %in% known) |> distinct(record_id) |> nrow()
    if (no_hosp > 0) out <- c(out, paste0("**", no_hosp, " mother", if (no_hosp > 1) "s have" else " has",
                                          " no hospital recorded** (blank or missing code in Hospital ID): they count in the network totals but not in any site's report. **Action:** complete Hospital ID."))
    site <- bh |> group_by(hosp) |> summarise(pct = sum(nd) / sum(ne), ne = sum(ne), .groups = "drop") |> arrange(pct)
    if (nrow(site) >= 2) {
      low <- site |> filter(pct < good) |> head(max_items)
      out <- c(out, paste0("**Site ranking:** highest ", short(tail(site$hosp, 1)), " (", pc(tail(site$pct, 1)), ")",
                           if (nrow(low)) paste0("; lowest ", paste0(short(low$hosp), " (", pc(low$pct), ")", collapse = ", ")) else "",
                           ". **Action:** pair low-performing sites with the strongest for peer learning."))
      shared <- bh |> filter(ne >= min_n) |> group_by(row, label) |>
        summarise(n_sites = n(), n_low = sum(pct < caution), .groups = "drop") |>
        filter(n_sites >= 2, n_low / n_sites >= 0.5) |> arrange(desc(n_low / n_sites)) |> head(max_items)
      if (nrow(shared))
        out <- c(out, paste0("**Network-wide gaps** (below ", pc(caution), " in at least half of sites): ",
                             paste0(shared$label, " (", shared$n_low, " of ", shared$n_sites, " sites)", collapse = "; "),
                             ". **Action:** address these in network-wide training and mentorship."))
    }
  }

  # 7. disabled forms (last: it is for the CIN data team, not the ward)
  dis_rows <- rv$row[!rv$row %in% cur$row & vapply(rv$fields_list, function(fs) TRUE, TRUE)]
  dis_rows <- intersect(dis_rows, unique(x$doc$row[x$doc$disabled]))
  if (length(dis_rows))
    out <- c(out, paste0("**", length(dis_rows), " of ", nrow(rv), " report variables cannot be documented** because the ",
                         and_list(form_title(x$fdl$disabled)),
                         " forms are disabled in REDCap (labour, delivery and outcome sections). **Action for the CIN data team:** re-enable these forms."))
  out
}
