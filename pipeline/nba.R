# NBA: points, assists, rebounds and PRA. Run from the repo root: Rscript pipeline/nba.R
source("pipeline/common.R")

clean_nba <- function(raw) {
  if (!all(c("Date", "OPP") %in% names(raw))) return(data.frame())
  raw |>
    dplyr::mutate(
      Opp = trimws(.data$OPP),
      Date = normalize_espn_game_date(.data$Date),
      PTS = num(.data$PTS), AST = num(.data$AST), REB = num(.data$REB),
      PRA = .data$PTS + .data$AST + .data$REB
    ) |>
    dplyr::filter(grepl("^(@|v)", .data$Opp), !is.na(.data$Date)) |>
    dplyr::distinct(Player_ID, Date, .keep_all = TRUE) |>
    dplyr::select(Player, Player_ID, Team, Date, Opp, PTS, AST, REB, PRA)
}

run_sport(
  sport = "nba",
  league = "basketball/nba",
  clean_fn = clean_nba,
  stats = c("PTS", "AST", "REB", "PRA"),
  stat_labels = c(PTS = "Points", AST = "Assists", REB = "Rebounds", PRA = "Pts+Reb+Ast")
)
