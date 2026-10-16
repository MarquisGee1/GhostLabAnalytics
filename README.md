# Locked In Analytics

One installable web app (PWA) for NBA, WNBA and MLB player stats, refreshed automatically every morning.

```
GitHub Actions (daily, 7am ET)
  └─ pipeline/nba.R                  adds new ESPN box scores → JSON
       └─ `site` branch               app + data, overwritten each run
            └─ Cloudflare Pages        auto-deploys the branch → users' phones
```

| Path | What it is |
|---|---|
| `pipeline/common.R` | Shared scraping, date parsing and JSON export |
| `pipeline/nba.R` | NBA, from ESPN's box score API (live) |
| `pipeline/wnba.R`, `mlb.R` | Old HTML scrapers, paused: ESPN's website blocks GitHub's servers |
| `pwa/` | The app: `index.html`, `app.js`, `styles.css`, `sw.js` |
| `pwa/config.js` | Sports, free vs Pro limits, price, Stripe link |
| `pwa/data/picks.json` | Your daily picks (only file in `data/` you edit by hand) |
| `.github/workflows/refresh.yml` | The automation |

## One-time setup (about 15 minutes)

1. **Create the GitHub repo.** On github.com, create a new repository named `lockedin-analytics`.
   Make it **public**, because public repos get unlimited Actions minutes. In-season scraping
   can use about 2,000 minutes a month, which is the entire free allowance for private repos.
   Then from this folder:
   ```bash
   git init && git add -A && git commit -m "Initial commit"
   git branch -M main
   git remote add origin https://github.com/<you>/lockedin-analytics.git
   git push -u origin main
   ```
2. **Run the first full scrape.** In the repo, open Actions → "Refresh data and deploy" → Run workflow,
   and tick **full_refresh**. It takes about an hour (MLB is the slowest). When it finishes,
   a `site` branch exists.
3. **Host it.** On Cloudflare (free plan), go to Workers & Pages → Create → Pages → Connect to Git.
   Choose the repo, set **Production branch: `site`**, leave the build command empty, and set the
   output directory to `/`. Every daily run now deploys automatically.
   (Netlify works the same way: deploy branch `site`, publish directory `/`.)

After that, nothing is manual. To change the app, edit files in `pwa/` and push to `main`.
The site redeploys within a minute and installed apps update on their next launch.

## Daily picks
Edit `pwa/data/picks.json` on GitHub (pencil icon → commit). Example:
```json
{ "date": "2026-10-21", "picks": [{ "sport": "nba", "text": "Tatum over 27.5 PTS" }] }
```

## Run locally
```bash
LOCKEDIN_TEAMS=BOS Rscript pipeline/nba.R                # quick one-team backfill
python3 -m http.server 8765 --directory pwa               # open http://localhost:8765
```
Add `?pro=1` to the URL to preview Pro, or `?pro=0` for free.

## How NBA data is stored
Every game is downloaded once and kept. The first run backfills the seasons listed in
`pipeline/nba.R` (about 1,300 games, roughly 30 minutes). Each daily run checks the last few
days of scoreboards and adds only games it hasn't seen, which is usually 5–15 API calls.
The processed game IDs are in `data/nba/events.json` on the `site` branch.

## Pipeline settings (environment variables)
- `LOCKEDIN_FULL_REFRESH=true` throws away stored data and backfills from scratch.
- `LOCKEDIN_TEAMS=BOS` limits a backfill to one team's games, for quick tests.
- `LOCKEDIN_TODAY=2026-03-05` pretends today is another date, for testing the daily update.
- `LOCKEDIN_API_DELAY=1` sets the seconds between ESPN API calls. Keep it polite.

## Before charging money
- **Pro unlock is a prototype.** It's a browser flag (`?pro=1`), and the data files are public.
  Real enforcement needs accounts plus a server check, for example Supabase Auth and a Stripe
  webhook that marks users Pro, with Pro-only data served from behind that login.
- **ESPN's terms don't permit commercial use** of scraped data. Plan to switch to a licensed feed
  (SportsDataIO, Sportradar, balldontlie). Only the `pipeline/` folder would change.
