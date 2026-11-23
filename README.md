# CIN-MNH Maternity Documentation Report

Weekly **documentation-completeness** reports for the CIN Standard Maternal Tool (REDCap PID 80), one per hospital plus one for the whole CIN-MNH network.

Each report contains:

- **Key takeaways for action**, generated from the data: overall level and change vs last month, the variables that need immediate action, big drops and improvements, the weakest sections with a recommended action, and data-entry backlog warnings.
- **A weekly table**: one row per key variable of the monthly *Maternity Newborn Health Report*, one column per week. Each cell shows the % of mothers whose record documents the variable, with *documented / expected* underneath, colour-coded green / amber / red.
- **Network report only**: a variables × hospitals table, plus a site ranking and gaps shared across sites.

Outputs are a self-contained **HTML** file and a **PDF**, both ready to email.

> How it works inside, and why: see **[DESIGN.md](DESIGN.md)**.

---

## Contents

1. [Quick start](#1-quick-start)
2. [Installation](#2-installation)
3. [Running reports](#3-running-reports)
4. [What the numbers mean](#4-what-the-numbers-mean)
5. [Configuration files](#5-configuration-files)
6. [Maintenance tasks](#6-maintenance-tasks)
7. [Testing](#7-testing)
8. [Troubleshooting](#8-troubleshooting)
9. [Project layout](#9-project-layout)

---

## 1. Quick start

```bash
# once
cp .Renviron.example .Renviron          # then add your REDCap API URL and token
Rscript -e 'install.packages(c("REDCapR","dplyr","tidyr","purrr","stringr","readr","lubridate","knitr","rmarkdown","kableExtra"))'

# every month: all hospitals with data, plus the network report
Rscript R/render_batch.R --month 2026-10
# -> output/2026-10/Lodwar_2026-10.pdf, ..., CIN-MNH_Network_2026-10.pdf, batch_log.csv
```

To try it without REDCap access: `Rscript R/render_batch.R --month 2026-10 --source synthetic`.

---

## 2. Installation

### 2.1 Software

| Software | Version | Notes |
|---|---|---|
| R | ≥ 4.1 (tested 4.3.3) | The code uses the native pipe `\|>` |
| Quarto | ≥ 1.4 (tested 1.11) | Must be on the `PATH`: `quarto --version` should work in a terminal. The PDF is built with **Typst, which ships with Quarto, so you don't need LaTeX**. |
| R packages | see below | |

```r
install.packages(c(
  "REDCapR",    # REDCap API
  "dplyr", "tidyr", "purrr", "stringr", "readr", "lubridate",  # data handling
  "knitr", "rmarkdown", "kableExtra"                            # rendering
))
```

Tested with REDCapR 1.7, dplyr 1.1.4, tidyr 1.3.1, purrr 1.0.2, stringr 1.5.1, readr 2.1.5, lubridate 1.9.3, knitr 1.45, rmarkdown 2.25 and kableExtra 1.4.0.

**Recommended:** pin the versions with **renv** so every analyst gets the same results:

```r
install.packages("renv")
renv::init()       # first time, in the project folder
renv::snapshot()   # after installing or updating packages; commit renv.lock
renv::restore()    # on a new machine: installs exactly the locked versions
```

### 2.2 REDCap API access

1. In REDCap PID 80, **User Rights** → your user (or a dedicated service account) needs:
   - **API Export**
   - **Data Export Rights: "Remove All Identifier Fields" or "Full Data Set"**. The report pulls only 48 fields and **none of them is an identifier**, but it does need date fields (admission, data entry, CS and delivery dates and times). The *De-Identified* level removes all dates and would break the report.
   - **No Data Access Group.** A user in a DAG only sees that DAG's records, which would make the network report incomplete.
2. **API** → generate a token.
3. Copy `.Renviron.example` to `.Renviron` in the project folder:

   ```
   REDCAP_URI=https://<your-redcap-server>/api/
   REDCAP_TOKEN=<32-character token>
   ```

   **Never commit `.Renviron`.** It is already in `.gitignore`. Restart R after editing it.

4. Check the connection:

   ```r
   readRenviron(".Renviron")
   REDCapR::redcap_metadata_read(Sys.getenv("REDCAP_URI"), Sys.getenv("REDCAP_TOKEN"))$success   # TRUE
   ```

### 2.3 First run

```bash
Rscript tests/test_pipeline.R            # should end with PIPELINE OK, CELL TEXT OK, TAKEAWAYS OK
Rscript tests/test_live_path.R           # LIVE PATH OK, BOUNDARY OK
quarto render doc_table.qmd -P source:synthetic -P month:2026-10    # doc_table.html / .pdf
```

---

## 3. Running reports

### 3.1 Batch: the normal monthly run

```bash
Rscript R/render_batch.R --month 2026-10                       # all hospitals with data + network
Rscript R/render_batch.R --month 2026-10 --hospitals 91,72     # selected hospitals (+ network)
Rscript R/render_batch.R --month 2026-10 --no-network          # hospitals only
Rscript R/render_batch.R --start 2026-10-12 --end 2026-11-08   # custom period
Rscript R/render_batch.R --month 2026-10 --formats pdf         # PDF only (html,pdf is the default)
Rscript R/render_batch.R --month 2026-10 --out /shared/reports # another output folder
Rscript R/render_batch.R --month 2026-10 --source synthetic    # test data
```

With no `--month` or `--start/--end`, the batch reports on the **last full calendar month**.

What the batch does:
1. Pulls REDCap **once**, for all hospitals, covering the report period and the previous period (needed for the comparison).
2. Gives a report only to hospitals with **at least one mother** in the period; it lists the rest as skipped.
3. Renders each hospital, then the network, into `output/<period>/`:

```
output/2026-10/
├── Lodwar_2026-10.html / .pdf
├── Pumwani_2026-10.html / .pdf
├── ...
├── CIN-MNH_Network_2026-10.html / .pdf
└── batch_log.csv          # report, hosp_id, mothers, files, status (ok / FAILED)
```

4. Deletes its temporary copy of the data. If any report fails, the script exits with status 1, so check `batch_log.csv`.

### 3.2 A single report

```bash
quarto render doc_table.qmd -P hospital:91 -P month:2026-10
quarto render doc_table.qmd -P hospital:all -P month:2026-10      # network
quarto render doc_table.qmd -P hospital:72 -P start_date:2026-10-12 -P end_date:2026-11-08
quarto render doc_table.qmd -P hospital:91 --to typst             # PDF only
```

| Parameter | Default | Meaning |
|---|---|---|
| `source` | `redcap` | `redcap` (API) or `synthetic` (test data) |
| `hospital` | `91` | a `hosp_id` code, or `all` for the network. **An empty value is ignored by Quarto; use `all`.** |
| `month` | last full month | `YYYY-MM` |
| `start_date`, `end_date` | — | custom period (both needed; overrides `month`) |
| `good` | `0.90` | ≥ this is green (optimal) |
| `caution` | `0.70` | ≥ this is amber (needs attention); below is red (requires immediate action) |
| `cache` | — | set by the batch script; leave empty |

Hospital codes: 72 Pumwani · 54 Mbagathi · 53 Mama Lucy · 83 Kilifi · 52 Machakos · 40 Nakuru · 51 Kiambu · 76 Bungoma · 91 Lodwar · 92 Garissa · 63 Kakamega.

---

## 4. What the numbers mean

| Term | Definition |
|---|---|
| **Week** | Monday-start week of the mother's `admission_date`. If that is blank or a missing code, `datetime_entry` (the date the record was created) is used. The first and last columns are clipped to the period, so they may be partial weeks. |
| **Expected** | REDCap would show the question for this mother: its form is enabled by the **form display logic** *and* its **branching logic** is true. Example: *Referral type* is expected only for referred mothers. |
| **Documented** | The field holds a real answer. `OTH` ("Other (specify)") counts as documented. `NI, INV, UNK, NA, ND, QI` count as **missing**. A checkbox counts as documented when at least one option is ticked. |
| **Cell** | documented ÷ expected for that week, shown as a % **rounded down**, so a cell never shows 100% while gaps remain. |
| **–** | No mother was expected to have the variable that week, or its form is disabled. |
| **Form disabled** | The REDCap form display logic can never enable the form (e.g. `1=2`). At present this applies to **Delivery Details, Post Delivery and Newborn Details**, which blocks 9 of the 41 rows. |
| **Previous period** | The previous calendar month for a monthly report; otherwise the same number of days immediately before. |

---

## 5. Configuration files

Everything you're likely to change is in `config/`. **No code changes are needed.**

| File | Purpose | Columns |
|---|---|---|
| `report_variables.csv` | The rows of the table | `section`, `label`, `fields` (several separated by `\|`, all must be documented), `expected_when` (optional extra REDCap logic) |
| `section_actions.csv` | The **Action:** text in the takeaways | `section` (must match `report_variables.csv` exactly), `action` |
| `hospitals.csv` | Short names for column headers and file names | `hosp_id`, `name`, `short` |
| `form_display_logic.csv` | REDCap form display logic (the API cannot export it) | REDCap export format |
| `metadata.csv` | Data dictionary; used for synthetic data only. Live runs read it from the API. | REDCap export format |

---

## 6. Maintenance tasks

### Monthly
1. `Rscript R/render_batch.R --month YYYY-MM`
2. Check `output/YYYY-MM/batch_log.csv`: every row should say `ok`.
3. Open the **network** report first. Its takeaways flag network-wide issues, such as mothers with no hospital recorded or disabled forms.
4. Send each hospital its own file.

### When the REDCap form display logic changes (e.g. the delivery forms are re-enabled)
1. REDCap → Online Designer → **Form Display Logic** → **Export** → save as `config/form_display_logic.csv`.
2. Re-render. Rows that showed "Form disabled" will now show percentages.

### When the data dictionary changes
1. Export the data dictionary and save it as `config/metadata.csv` (for synthetic tests; live runs read it from the API).
2. If a field used in `report_variables.csv` was renamed or removed, update that file.
3. Run `Rscript tests/test_pipeline.R`. A missing field shows up as an error naming the field.

### Add or remove a report variable
Edit `config/report_variables.csv`. Use the REDCap variable name, and keep `section` consistent with `section_actions.csv`. The variable must be on a **non-repeating** form (see DESIGN.md §9).

### Add a hospital
Add a row to `config/hospitals.csv` (`hosp_id` must match the code in the REDCap `hosp_id` field). It gets a report automatically once it has mothers in a period.

### Change thresholds or the action wording
- Colours: change `good` / `caution` in the `params:` block of `doc_table.qmd`.
- Takeaway rules (minimum number of mothers, size of a notable change): the defaults of `build_takeaways()` in `R/takeaways.R`.
- Wording: edit `config/section_actions.csv`.

### Update packages safely
`renv::update()`, then run both tests and a synthetic batch, then `renv::snapshot()` and commit `renv.lock`.

---

## 7. Testing

```bash
Rscript tests/test_pipeline.R
Rscript tests/test_live_path.R
```

| Test | Checks |
|---|---|
| `test_pipeline.R` | Disabled-form detection; expected and documented counts against an independent calculation; the OTH/ND rule; cell text; takeaway numbers match the table; the network ranking and the no-hospital count |
| `test_live_path.R` | The REDCap code path, with REDCapR replaced by a stand-in server: the same table as the synthetic run, no names or phone numbers pulled, and a data-entry time late on the last day still counted in the period |

Run both after any change to `R/`, `doc_table.qmd` or `config/`. No REDCap access is needed.

---

## 8. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Set REDCAP_URI and REDCAP_TOKEN in .Renviron` | `.Renviron` is missing or not in the project folder. Restart R after creating it. |
| `REDCap export failed: ... 403` | The token is wrong or lacks *API Export* rights. |
| Dates missing, or every row near 0% | The token's export rights are *De-Identified*, which strips dates. Use *Remove All Identifier Fields* or *Full Data Set*. |
| Network report has fewer mothers than expected | The API user is in a Data Access Group; use a user without one. |
| `No records for this hospital and period` | Nobody was admitted in that period. Check the `--month` / dates and the `hosp_id` code. |
| `-P hospital:""` gives Lodwar, not the network | Quarto ignores empty parameter values. Use `-P hospital:all`. |
| PDF fails with `the document does not contain a bibliography` | A label or action contains `@word`, which pandoc reads as a citation. The table helper escapes `@`; if you added `@` in new text outside a table, write it as `\@`. |
| `quarto: command not found` (batch) | Quarto isn't on the `PATH` used by `Rscript`. Add it, or run from a terminal where `quarto --version` works. |
| Odd characters (`<U+2212>`) in the console | The R session isn't using UTF-8. The rendered reports are fine; on Linux run with `LC_ALL=C.UTF-8`. |
| A batch report `FAILED` | Re-run that one report with `quarto render doc_table.qmd -P hospital:<code> -P month:<YYYY-MM>` to see the error. |

---

## 9. Project layout

```
cin-mnh-doc-table/
├── doc_table.qmd            # the report (HTML + PDF)
├── R/
│   ├── pipeline.R           # REDCap pull, expected/documented logic, weekly table
│   ├── redcap_logic.R       # REDCap branching/display logic evaluated in R
│   ├── takeaways.R          # rule-based key takeaways
│   ├── render_batch.R       # all hospitals + network in one run
│   └── synthetic.R          # synthetic data for tests and demos
├── config/                  # everything you're expected to edit (see §5)
├── tests/                   # test_pipeline.R, test_live_path.R
├── page.typ                 # PDF page setup (A4 landscape)
├── styles.css               # HTML table styling
├── .Renviron.example        # template for API credentials
├── README.md                # this file
└── DESIGN.md                # architecture and design decisions
```
