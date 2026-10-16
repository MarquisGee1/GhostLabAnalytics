# NBA from ESPN box scores: points, assists, rebounds and PRA. Run from the repo root: Rscript pipeline/nba.R
# First run backfills the seasons below; later runs only add games from the last few days.
source("pipeline/common.R")

run_boxscore_sport(
  sport = "nba",
  league = "basketball/nba",
  stat_labels = c(PTS = "PTS", AST = "AST", REB = "REB"),
  derive_fn = function(rows) dplyr::mutate(rows, PRA = PTS + AST + REB),
  stats = c("PTS", "AST", "REB", "PRA"),
  display_labels = c(PTS = "Points", AST = "Assists", REB = "Rebounds", PRA = "Pts+Reb+Ast"),
  backfill_seasons = c(2026, 2027) # 2025-26 season plus the new 2026-27 season
)
