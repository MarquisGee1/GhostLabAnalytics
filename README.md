# Locked In Analytics

One installable web app (PWA) for NBA, WNBA and MLB player stats, refreshed automatically every morning.

```
GitHub Actions (daily, 7am ET)
  └─ pipeline/nba.R, wnba.R, mlb.R   scrape ESPN in parallel → JSON
       └─ `site` branch               app + data, overwritten each run
            └─ Cloudflare Pages        auto-deploys the branch → users' phones
```

| Path | What it is |
|---|---|
| `pipeline/common.R` | Shared scraping, date parsing and JSON export |
| `pipeline/<sport>.R` | Per-sport cleaning and stats (ported from your Shiny apps) |
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
Rscript pipeline/wnba.R                                   # or LOCKEDIN_TEAMS=BOS Rscript pipeline/nba.R
python3 -m http.server 8765 --directory pwa               # open http://localhost:8765
```
Add `?pro=1` to the URL to preview Pro, or `?pro=0` for free.

## Pipeline settings (environment variables)
- `LOCKEDIN_FULL_REFRESH=true` scrapes every team. By default a run scrapes teams that played
  yesterday or play today, plus any team that has no data yet.
- `LOCKEDIN_TEAMS=BOS,NYY` scrapes only these teams.
- `LOCKEDIN_SCRAPE_DELAY=2` sets the seconds between player pages. Keep it polite.

## Before charging money
- **Pro unlock is a prototype.** It's a browser flag (`?pro=1`), and the data files are public.
  Real enforcement needs accounts plus a server check, for example Supabase Auth and a Stripe
  webhook that marks users Pro, with Pro-only data served from behind that login.
- **ESPN's terms don't permit commercial use** of scraped data. Plan to switch to a licensed feed
  (SportsDataIO, Sportradar, balldontlie). Only the `pipeline/` folder would change.
