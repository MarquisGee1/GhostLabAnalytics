# WNBA: points, assists, rebounds. Run from the repo root: Rscript pipeline/wnba.R
source("pipeline/common.R")

clean_wnba <- function(raw) {
  if (!all(c("Date", "OPP") %in% names(raw))) return(data.frame())
  raw |>
    dplyr::mutate(
      Opp = trimws(.data$OPP),
      Date = normalize_espn_game_date(.data$Date),
      PTS = num(.data$PTS), AST = num(.data$AST), REB = num(.data$REB)
    ) |>
    dplyr::filter(grepl("^(@|v)", .data$Opp), !is.na(.data$Date)) |>
    dplyr::distinct(Player_ID, Date, .keep_all = TRUE) |>
    dplyr::select(Player, Player_ID, Team, Date, Opp, PTS, AST, REB)
}

run_sport(
  sport = "wnba",
  league = "basketball/wnba",
  clean_fn = clean_wnba,
  stats = c("PTS", "AST", "REB"),
  stat_labels = c(PTS = "Points", AST = "Assists", REB = "Rebounds")
)
