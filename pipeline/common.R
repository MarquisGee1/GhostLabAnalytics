# Shared ESPN scraping + JSON export for the Locked In Analytics pipeline.
# Each sport script (wnba.R, nba.R, mlb.R) defines a clean_fn and calls run_sport().
#
# Environment variables:
#   LOCKEDIN_FULL_REFRESH=true   scrape every team, not just teams that played yesterday / play today
#   LOCKEDIN_TEAMS=IND,LVA       scrape only these teams (handy for testing)
#   LOCKEDIN_SCRAPE_DELAY=2      seconds to wait between player pages (be polite to ESPN)
#   APP_TIMEZONE                 defaults to America/New_York

for (pkg in c("dplyr", "httr2", "jsonlite", "rvest", "stringr", "xml2")) {
  if (!requireNamespace(pkg, quietly = TRUE)) install.packages(pkg, repos = "https://cloud.r-project.org")
}

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

app_timezone <- Sys.getenv("APP_TIMEZONE", unset = "America/New_York")
today <- as.Date(format(Sys.time(), tz = app_timezone))
scrape_delay <- as.numeric(Sys.getenv("LOCKEDIN_SCRAPE_DELAY", unset = "2"))

espn_get <- function(url, json = FALSE) {
  # Plain client headers on purpose: ESPN answers a spoofed browser user agent with an empty 202.
  req <- httr2::request(url) |>
    httr2::req_timeout(30) |>
    httr2::req_retry(max_tries = 3, backoff = function(i) 5 * i)

  resp <- tryCatch(httr2::req_perform(req), error = function(e) {
    message("  request failed: ", url, " (", conditionMessage(e), ")")
    NULL
  })
  if (is.null(resp) || httr2::resp_status(resp) != 200 || length(httr2::resp_body_raw(resp)) == 0) {
    if (!is.null(resp)) message("  empty response (", httr2::resp_status(resp), "): ", url)
    return(NULL)
  }
  if (json) httr2::resp_body_json(resp, simplifyVector = FALSE) else xml2::read_html(httr2::resp_body_string(resp))
}

# league is the ESPN API path, e.g. "basketball/wnba" or "baseball/mlb".
get_scheduled_team_abbrs <- function(league, game_date) {
  scoreboard <- espn_get(paste0(
    "https://site.api.espn.com/apis/site/v2/sports/", league, "/scoreboard?dates=",
    format(game_date, "%Y%m%d"), "&limit=100"
  ), json = TRUE)

  abbrs <- unlist(lapply(scoreboard$events %||% list(), function(event) {
    vapply(event$competitions[[1]]$competitors, function(c) c$team$abbreviation %||% NA_character_, character(1))
  }), use.names = FALSE)
  sort(unique(stats::na.omit(toupper(abbrs))))
}

get_all_team_abbrs <- function(league) {
  teams <- espn_get(paste0("https://site.api.espn.com/apis/site/v2/sports/", league, "/teams?limit=100"), json = TRUE)
  team_list <- teams$sports[[1]]$leagues[[1]]$teams %||% list()
  sort(unique(toupper(vapply(team_list, function(t) t$team$abbreviation %||% NA_character_, character(1)))))
}

scrape_team_roster <- function(sport, team_abbr) {
  page <- espn_get(paste0("https://www.espn.com/", sport, "/team/roster/_/name/", tolower(team_abbr)))
  if (is.null(page)) return(NULL)

  nodes <- rvest::html_nodes(page, "a.AnchorLink")
  names <- rvest::html_text(nodes, trim = TRUE)
  links <- rvest::html_attr(nodes, "href")
  valid <- grepl(paste0("/", sport, "/player/(_|stats/_)/id/"), links)
  if (!any(valid)) return(NULL)
  slugs <- stringr::str_match(links, "/id/[0-9]+/([^/?#]+)")[, 2]
  names <- ifelse(names == "" | is.na(names), stringr::str_to_title(gsub("-", " ", slugs)), names)

  data.frame(
    Player = names[valid],
    Player_ID = stringr::str_extract(links[valid], "(?<=/id/)[0-9]+"),
    Team = toupper(team_abbr),
    stringsAsFactors = FALSE
  ) |>
    dplyr::filter(Player != "", !is.na(Player_ID)) |>
    dplyr::distinct(Player_ID, .keep_all = TRUE)
}

scrape_player_gamelog <- function(sport, player_id, player_name, team_abbr) {
  page <- espn_get(paste0("https://www.espn.com/", sport, "/player/gamelog/_/id/", player_id))
  if (scrape_delay > 0) Sys.sleep(scrape_delay)
  if (is.null(page)) return(NULL)

  tables <- rvest::html_nodes(page, "table.Table")
  if (length(tables) == 0) tables <- rvest::html_nodes(page, "table")
  if (length(tables) == 0) return(NULL)

  log <- tables |>
    lapply(function(tbl) {
      df <- rvest::html_table(tbl, fill = TRUE)
      names(df) <- make.unique(names(df), sep = "_")
      df[] <- lapply(df, as.character)
      df
    }) |>
    dplyr::bind_rows(.id = "Table_ID")
  if (nrow(log) == 0) return(NULL)

  log$Player <- player_name
  log$Player_ID <- player_id
  log$Team <- toupper(team_abbr)
  log
}

# ESPN game logs show "Sat 8/23" with no year; infer it from the season window.
normalize_espn_game_date <- function(date_values, current_date = today) {
  date_text <- trimws(as.character(date_values))
  date_text <- sub("^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)[a-z]*,?\\s+", "", date_text, ignore.case = TRUE)
  date_text[date_text == ""] <- NA_character_
  current_year <- as.integer(format(current_date, "%Y"))
  prior_year <- current_year - 1
  prior_year_start <- as.Date(sprintf("%04d-01-01", prior_year))
  current_month_day <- as.Date(sprintf("%04d-%s", prior_year, format(current_date, "%m-%d")))

  parse_with <- function(values, formats) {
    parsed <- as.Date(rep(NA_real_, length(values)), origin = "1970-01-01")
    for (fmt in formats) {
      todo <- is.na(parsed) & !is.na(values)
      if (!any(todo)) break
      parsed[todo] <- suppressWarnings(as.Date(values[todo], format = fmt))
    }
    parsed
  }

  explicit <- parse_with(date_text, c("%Y-%m-%d", "%m/%d/%Y", "%m/%d/%y", "%b %d %Y", "%B %d %Y"))
  prior <- parse_with(paste(date_text, prior_year), c("%m/%d %Y", "%b %d %Y", "%B %d %Y"))
  current <- parse_with(paste(date_text, current_year), c("%m/%d %Y", "%b %d %Y", "%B %d %Y"))

  season <- dplyr::if_else(
    !is.na(prior) & prior >= prior_year_start & prior <= current_month_day,
    current, prior
  )
  dplyr::coalesce(explicit, season)
}

num <- function(x) suppressWarnings(as.numeric(x))

# ---------- JSON export ----------

write_team_json <- function(rows, team_file) {
  rows <- rows[order(rows$Player, rows$Date), , drop = FALSE]
  rows$Date <- format(as.Date(rows$Date), "%Y-%m-%d")
  rownames(rows) <- NULL
  jsonlite::write_json(
    list(team = rows$Team[1], rows = rows),
    team_file,
    auto_unbox = TRUE, dataframe = "rows", na = "null", digits = NA
  )
}

write_meta_json <- function(sport_dir, sport, stats, stat_labels, groups, rate_stats) {
  team_files <- list.files(file.path(sport_dir, "teams"), pattern = "\\.json$", full.names = TRUE)
  teams <- lapply(team_files, function(f) {
    rows <- jsonlite::read_json(f, simplifyVector = TRUE)$rows
    list(
      abbr = sub("\\.json$", "", basename(f)),
      players = sort(unique(rows$Player)),
      latest_game = max(rows$Date)
    )
  })

  meta <- list(
    sport = sport,
    updated = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
    latest_game = max(vapply(teams, `[[`, character(1), "latest_game")),
    stats = stats,
    stat_labels = as.list(stat_labels),
    groups = groups,
    rate_stats = rate_stats,
    teams = teams
  )
  jsonlite::write_json(meta, file.path(sport_dir, "meta.json"), auto_unbox = TRUE, pretty = TRUE, null = "null")
}

# ---------- Driver ----------

# clean_fn(raw_log_df) must return Player, Player_ID, Team, Date, Opp, [Status], and the stat columns.
# groups: optional list(list(id = "Batting", stats = c(...), labels = list(H = "Hits")), ...)
#         for sports where each row belongs to a role (MLB batting vs pitching).
run_sport <- function(sport, league, clean_fn, stats, stat_labels, groups = NULL,
                      rate_stats = character(), out_root = "pwa/data") {
  started <- Sys.time()
  sport_dir <- file.path(out_root, sport)
  team_dir <- file.path(sport_dir, "teams")
  dir.create(team_dir, recursive = TRUE, showWarnings = FALSE)

  team_override <- Sys.getenv("LOCKEDIN_TEAMS")
  full_refresh <- identical(tolower(Sys.getenv("LOCKEDIN_FULL_REFRESH")), "true") ||
    length(list.files(team_dir)) == 0

  teams <- if (nzchar(team_override)) {
    toupper(trimws(strsplit(team_override, ",")[[1]]))
  } else if (full_refresh) {
    get_all_team_abbrs(league)
  } else {
    # Yesterday's teams have a new game in their logs; today's teams are on the current slate.
    # Any team without a file yet (new franchise, earlier failure) is backfilled.
    existing <- sub("\\.json$", "", list.files(team_dir, pattern = "\\.json$"))
    union(
      union(get_scheduled_team_abbrs(league, today - 1), get_scheduled_team_abbrs(league, today)),
      setdiff(get_all_team_abbrs(league), existing)
    )
  }

  message(sprintf("[%s] %s refresh, %d teams: %s", sport, if (full_refresh) "full" else "daily",
                  length(teams), paste(teams, collapse = " ")))
  if (length(teams) == 0) {
    message("[", sport, "] No games yesterday or today. Keeping existing data.")
    return(invisible(FALSE))
  }

  updated <- 0
  for (team in teams) {
    roster <- scrape_team_roster(sport, team)
    if (is.null(roster) || nrow(roster) == 0) {
      message("[", sport, "] ", team, ": roster unavailable, keeping previous data")
      next
    }
    message("[", sport, "] ", team, ": ", nrow(roster), " players")

    logs <- lapply(seq_len(nrow(roster)), function(i) {
      scrape_player_gamelog(sport, roster$Player_ID[i], roster$Player[i], team)
    })
    raw <- dplyr::bind_rows(logs)
    clean <- if (nrow(raw) > 0) clean_fn(raw) else data.frame()
    if (nrow(clean) == 0) {
      message("[", sport, "] ", team, ": no game rows, keeping previous data")
      next
    }

    write_team_json(clean, file.path(team_dir, paste0(team, ".json")))
    updated <- updated + 1
  }

  if (length(list.files(team_dir)) == 0) stop("[", sport, "] No data scraped.", call. = FALSE)
  write_meta_json(sport_dir, sport, stats, stat_labels, groups, rate_stats)
  message(sprintf("[%s] Done: %d/%d teams updated in %.1f min", sport, updated, length(teams),
                  as.numeric(difftime(Sys.time(), started, units = "mins"))))
  invisible(TRUE)
}
