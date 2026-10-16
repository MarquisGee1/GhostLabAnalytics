# Shared ESPN scraping + JSON export for the Locked In Analytics pipeline.
# NBA uses the box score pipeline (run_boxscore_sport); WNBA and MLB still use HTML scraping (run_sport).
#
# Environment variables:
#   LOCKEDIN_FULL_REFRESH=true   scrape every team, not just teams that played yesterday / play today
#   LOCKEDIN_TEAMS=IND,LVA       scrape only these teams (handy for testing)
#   LOCKEDIN_SCRAPE_DELAY=2      seconds to wait between player pages (be polite to ESPN)
#   LOCKEDIN_API_DELAY=1         seconds to wait between ESPN API calls (box score sports)
#   LOCKEDIN_TODAY=2026-01-15    pretend today is this date (testing)
#   APP_TIMEZONE                 defaults to America/New_York

for (pkg in c("dplyr", "httr2", "jsonlite", "rvest", "stringr", "xml2")) {
  if (!requireNamespace(pkg, quietly = TRUE)) install.packages(pkg, repos = "https://cloud.r-project.org")
}

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

app_timezone <- Sys.getenv("APP_TIMEZONE", unset = "America/New_York")
today <- as.Date(Sys.getenv("LOCKEDIN_TODAY", unset = format(Sys.time(), "%Y-%m-%d", tz = app_timezone)))
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

# ---------- Box score pipeline (ESPN JSON API) ----------
# Used by sports that have moved off HTML scraping. www.espn.com blocks cloud servers such as
# GitHub Actions, but site.api.espn.com does not. Instead of re-scraping every player's game log,
# this keeps all rows already collected and appends box scores for games not yet processed:
# a one-time backfill of whole seasons, then only the last few days on each run.

api_delay <- as.numeric(Sys.getenv("LOCKEDIN_API_DELAY", unset = "1"))

espn_api <- function(league, path) {
  if (api_delay > 0) Sys.sleep(api_delay)
  espn_get(paste0("https://site.api.espn.com/apis/site/v2/sports/", league, "/", path), json = TRUE)
}

# Completed regular season (2) and postseason (3) games as a data frame of id + start time.
completed_events <- function(events) {
  rows <- lapply(events %||% list(), function(e) {
    comp <- e$competitions[[1]]
    season_type <- e$season$type %||% e$seasonType$type %||% NA
    if (!isTRUE(comp$status$type$completed) || !(as.character(season_type) %in% c("2", "3"))) return(NULL)
    data.frame(id = as.character(e$id), date = e$date %||% comp$date, stringsAsFactors = FALSE)
  })
  dplyr::bind_rows(rows)
}

season_events <- function(league, team_abbrs, seasons) {
  combos <- expand.grid(team = team_abbrs, season = seasons, type = c(2, 3), stringsAsFactors = FALSE)
  rows <- lapply(seq_len(nrow(combos)), function(i) {
    sched <- espn_api(league, sprintf("teams/%s/schedule?season=%s&seasontype=%s",
                                      tolower(combos$team[i]), combos$season[i], combos$type[i]))
    completed_events(sched$events)
  })
  dplyr::distinct(dplyr::bind_rows(rows), id, .keep_all = TRUE)
}

recent_events <- function(league, days) {
  rows <- lapply(days, function(d) {
    completed_events(espn_api(league, paste0("scoreboard?limit=100&dates=", format(d, "%Y%m%d")))$events)
  })
  dplyr::distinct(dplyr::bind_rows(rows), id, .keep_all = TRUE)
}

# One row per player who played. stat_labels maps output column -> ESPN box score label.
boxscore_rows <- function(league, event_id, stat_labels) {
  summary <- espn_api(league, paste0("summary?event=", event_id))
  comp <- summary$header$competitions[[1]]
  teams <- summary$boxscore$players
  if (is.null(comp) || length(teams) == 0) return(NULL)

  game_date <- as.Date(format(as.POSIXct(comp$date, format = "%Y-%m-%dT%H:%MZ", tz = "UTC"), tz = app_timezone))
  sides <- vapply(comp$competitors, function(c) c$homeAway, character(1))
  abbrs <- vapply(comp$competitors, function(c) toupper(c$team$abbreviation), character(1))

  dplyr::bind_rows(lapply(teams, function(team) {
    abbr <- toupper(team$team$abbreviation)
    side <- sides[abbrs == abbr]
    opp <- abbrs[abbrs != abbr]
    block <- team$statistics[[1]]
    labels <- unlist(block$labels)
    dplyr::bind_rows(lapply(block$athletes, function(a) {
      stats <- unlist(a$stats)
      # Skip DNPs and the occasional athlete ESPN lists without an id or name.
      if (isTRUE(a$didNotPlay) || length(stats) == 0 || is.null(a$athlete$id) || is.null(a$athlete$displayName)) return(NULL)
      row <- data.frame(
        Player = a$athlete$displayName,
        Player_ID = as.character(a$athlete$id),
        Team = abbr,
        Date = game_date,
        Opp = paste0(if (identical(side, "home")) "vs" else "@", opp),
        Event_ID = as.character(event_id),
        stringsAsFactors = FALSE
      )
      for (col in names(stat_labels)) row[[col]] <- num(stats[match(stat_labels[[col]], labels)])
      row
    }))
  }))
}

read_all_rows <- function(team_dir) {
  files <- list.files(team_dir, pattern = "\\.json$", full.names = TRUE)
  rows <- lapply(files, function(f) jsonlite::read_json(f, simplifyVector = TRUE)$rows)
  out <- dplyr::bind_rows(rows)
  if (nrow(out) > 0) out$Date <- as.Date(out$Date)
  out
}

# derive_fn(rows) can add computed stats (e.g. PRA). backfill_seasons are ESPN season years
# (the year a season ends: 2026 = the 2025-26 NBA season).
run_boxscore_sport <- function(sport, league, stat_labels, stats, display_labels,
                               backfill_seasons, derive_fn = identity, lookback_days = 4,
                               out_root = "pwa/data") {
  started <- Sys.time()
  sport_dir <- file.path(out_root, sport)
  team_dir <- file.path(sport_dir, "teams")
  events_file <- file.path(sport_dir, "events.json")
  dir.create(team_dir, recursive = TRUE, showWarnings = FALSE)

  rows <- read_all_rows(team_dir)
  processed <- if (file.exists(events_file)) unlist(jsonlite::read_json(events_file)$processed) else character()
  if (nrow(rows) == 0) processed <- character() # files were wiped; start over
  full_refresh <- identical(tolower(Sys.getenv("LOCKEDIN_FULL_REFRESH")), "true") || length(processed) == 0

  if (full_refresh) {
    message("[", sport, "] Backfilling seasons ", paste(backfill_seasons, collapse = ", "))
    rows <- rows[0, , drop = FALSE]
    processed <- character()
    team_override <- Sys.getenv("LOCKEDIN_TEAMS")
    teams <- if (nzchar(team_override)) toupper(strsplit(team_override, ",")[[1]]) else get_all_team_abbrs(league)
    candidates <- season_events(league, teams, backfill_seasons)
  } else {
    candidates <- recent_events(league, seq(today - lookback_days, today, by = "day"))
  }

  todo <- candidates[!candidates$id %in% processed, , drop = FALSE]
  todo <- todo[order(todo$date), , drop = FALSE]
  message(sprintf("[%s] %d completed games found, %d new", sport, nrow(candidates), nrow(todo)))

  new_rows <- list()
  for (i in seq_len(nrow(todo))) {
    game <- tryCatch(boxscore_rows(league, todo$id[i], stat_labels), error = function(e) {
      message("  game ", todo$id[i], " failed: ", conditionMessage(e))
      NULL
    })
    if (is.null(game) || nrow(game) == 0) next
    new_rows[[length(new_rows) + 1]] <- game
    processed <- c(processed, todo$id[i])
    if (i %% 100 == 0) message(sprintf("[%s]   %d/%d games", sport, i, nrow(todo)))
  }

  if (length(new_rows) == 0 && nrow(rows) == 0) stop("[", sport, "] No data collected.", call. = FALSE)
  if (length(new_rows) == 0) {
    message("[", sport, "] Nothing new. Keeping existing data.")
    return(invisible(FALSE))
  }

  all_rows <- dplyr::bind_rows(rows, derive_fn(dplyr::bind_rows(new_rows))) |>
    dplyr::distinct(Player_ID, Event_ID, .keep_all = TRUE)

  # File each player under the team of their most recent game, so traded players move with their games.
  current_team <- all_rows |>
    dplyr::group_by(Player_ID) |>
    dplyr::slice_max(Date, n = 1, with_ties = FALSE) |>
    dplyr::ungroup() |>
    dplyr::select(Player_ID, File_Team = Team)
  all_rows <- dplyr::left_join(all_rows, current_team, by = "Player_ID")

  unlink(list.files(team_dir, full.names = TRUE))
  for (team in sort(unique(all_rows$File_Team))) {
    team_rows <- all_rows[all_rows$File_Team == team, setdiff(names(all_rows), "File_Team")]
    team_rows$Team <- team
    write_team_json(team_rows, file.path(team_dir, paste0(team, ".json")))
  }
  jsonlite::write_json(list(processed = sort(unique(processed))), events_file, auto_unbox = FALSE)
  write_meta_json(sport_dir, sport, stats, display_labels, groups = NULL, rate_stats = character())

  message(sprintf("[%s] Done: +%d games, %d rows total, %.1f min", sport, length(new_rows), nrow(all_rows),
                  as.numeric(difftime(Sys.time(), started, units = "mins"))))
  invisible(TRUE)
}

# ---------- HTML scraping driver (WNBA/MLB; blocked from GitHub Actions) ----------

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
