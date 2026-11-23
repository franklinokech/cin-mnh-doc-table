# Synthetic REDCap export for testing without API access ----------------------------
# Shaped like REDCapR::redcap_read(raw_or_label = "raw"): all columns character,
# checkboxes as field___code, branching logic and form display logic respected (so the
# disabled forms stay empty), with blanks and missing-data codes varying by field and week.

simulate_records <- function(md, fields, fdl, missing_codes, start, end,
                             per_week = 60, seed = 80,
                             hospitals = c(`91` = .3, `72` = .25, `83` = .2, `52` = .15, `63` = .1)) {
  set.seed(seed)
  id <- md$field_name[1]
  mdf <- md |> filter(field_name %in% fields, field_name != id, field_type != "descriptive")
  days <- seq(start - 7, end + 7, by = "day")
  n <- round(per_week * length(days) / 7)
  adm <- sort(sample(days, n, TRUE))
  d <- tibble(!!id := as.character(seq_len(n)))
  wk <- as.numeric(adm - min(adm)) / max(1, as.numeric(diff(range(adm))))   # 0..1 through the period

  num_range <- list(mother_age = c(15, 44), parity_birth = c(0, 6), count_anc_visits = c(0, 8),
                    adm_bp_systolic = c(95, 170), adm_bp_diastolic = c(55, 110), adm_heart_rate = c(60, 125),
                    adm_temp = c(35.8, 38.4), adm_resp_rate = c(12, 24), adm_spo2 = c(90, 100), fhr_heard_per_min = c(110, 165))
  p_yes <- c(is_referral = .25, is_attended_anc = .9, is_fhr_heard = .95)

  for (i in seq_len(nrow(mdf))) {
    r <- mdf[i, ]; f <- r$field_name
    fl <- if (r$form_name %in% names(fdl$logic)) fdl$logic[[r$form_name]] else ""
    applies <- eval_redcap_logic(fl, d, missing_codes, warn_missing = FALSE) &
               eval_redcap_logic(r$branching_logic, d, missing_codes, warn_missing = FALSE)
    # documentation gap: field-specific level, improving or worsening through the period
    base_gap <- runif(1, .03, .55); slope <- sample(c(-.6, -.3, 0, .2), 1)
    site <- if ("hosp_id" %in% names(d)) c(`91` = 1, `72` = .5, `83` = 1.3, `52` = .8, `63` = 1.6)[d$hosp_id] else 1
    site[is.na(site)] <- 1
    gap <- applies & runif(n) < pmin(.95, pmax(0, base_gap * site * (1 + slope * wk) + rnorm(n, 0, .04)))
    if (r$field_type == "checkbox") {
      codes <- parse_choices(r$choices); pick <- sample(codes, n, TRUE)
      for (cd in codes) d[[paste0(f, "___", tolower(cd))]] <- ifelse(applies & !gap & pick == cd, "1", "0")
      next
    }
    v <- switch(r$field_type,
      yesno = ifelse(runif(n) < (if (f %in% names(p_yes)) p_yes[[f]] else .3), "1", "0"),
      radio = , dropdown = sample(parse_choices(r$choices), n, TRUE),
      sql = rep("Staff A", n),
      text = {
        if (f == "hosp_id") NA
        else if (grepl("^date", r$validation)) format(adm + sample(0:1, n, TRUE))
        else if (r$validation == "time") sprintf("%02d:%02d", sample(0:23, n, TRUE), sample(0:59, n, TRUE))
        else if (r$validation %in% c("integer", "number")) {
          rg <- if (f %in% names(num_range)) num_range[[f]] else c(0, 10)
          as.character(round(runif(n, rg[1], rg[2]), if (r$validation == "number") 1 else 0))
        } else rep("TXT", n)
      },
      rep("TXT", n))
    if (f == "hosp_id") v <- sample(names(hospitals), n, TRUE, hospitals)
    if (f == "admission_date") v <- format(adm)
    coded <- gap & runif(n) < .35
    v[!applies | gap] <- NA
    v[coded] <- sample(c("NI", "UNK", "ND", "OTH"), sum(coded), TRUE)
    if (f %in% c("hosp_id", "admission_date")) v[is.na(v)] <- if (f == "hosp_id") "91" else format(adm[is.na(v)])
    d[[f]] <- v
  }
  d$datetime_entry <- format(as.POSIXct(adm) + 3 * 86400, "%Y-%m-%d %H:%M:%S")
  d
}
