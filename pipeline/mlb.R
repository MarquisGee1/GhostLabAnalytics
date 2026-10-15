# MLB: batting and pitching logs, split by Status. Run from the repo root: Rscript pipeline/mlb.R
source("pipeline/common.R")

standardize_names <- function(x) {
  x <- gsub("%", "PCT", x, fixed = TRUE)
  x <- gsub("[-/]", "_", x)
  toupper(gsub("\\s+", "_", trimws(x)))
}

clean_mlb <- function(raw) {
  id_cols <- c("Player", "Player_ID", "Team")
  stat_part <- raw[setdiff(names(raw), id_cols)]
  names(stat_part) <- make.unique(standardize_names(names(stat_part)), sep = "_")
  df <- cbind(raw[id_cols], stat_part)
  if (!all(c("DATE", "OPP") %in% names(df))) return(data.frame())

  for (col in c("AB", "H", "R", "K", "P", "ERA", "HR", "AVG", "RBI", "IP")) {
    if (!col %in% names(df)) df[[col]] <- NA
  }

  df <- df |>
    dplyr::filter(grepl("^(@|v)", trimws(.data$OPP))) |>
    dplyr::mutate(
      Date = normalize_espn_game_date(.data$DATE),
      Opp = trimws(.data$OPP),
      dplyr::across(c("AB", "H", "R", "K", "P", "ERA", "HR", "AVG", "RBI", "IP"), num)
    )
  if ("PC_ST" %in% names(df)) df$P <- dplyr::coalesce(df$P, num(sub("-.*$", "", df$PC_ST)))

  df |>
    dplyr::mutate(Status = dplyr::case_when(
      !is.na(.data$AB) & .data$AB > 0 ~ "Batting",
      !is.na(.data$IP) | (!is.na(.data$P) & .data$P > 0) ~ "Pitching",
      TRUE ~ NA_character_
    )) |>
    dplyr::filter(!is.na(.data$Date), !is.na(.data$Status)) |>
    dplyr::distinct(Player_ID, Date, Status, .keep_all = TRUE) |>
    dplyr::select(Player, Player_ID, Team, Status, Date, Opp, H, HR, AB, RBI, AVG, IP, K, ERA)
}

run_sport(
  sport = "mlb",
  league = "baseball/mlb",
  clean_fn = clean_mlb,
  stats = c("H", "HR", "AB", "RBI", "AVG", "IP", "K", "ERA"),
  stat_labels = c(H = "Hits", HR = "Home Runs", AB = "At Bats", RBI = "RBI", AVG = "Average",
                  IP = "Innings Pitched", K = "Strikeouts", ERA = "ERA"),
  groups = list(
    list(id = "Batting", stats = c("H", "HR", "AB", "RBI", "AVG")),
    list(id = "Pitching", stats = c("IP", "H", "K", "HR", "ERA"),
         labels = list(H = "Hits Allowed", HR = "HR Allowed"))
  ),
  rate_stats = c("AVG", "ERA")
)
