// Locked In Analytics PWA: loads static JSON written by pipeline/*.R and renders the views
// the Shiny dashboards had (player trends, team compare, averages, game log, prop hit rate).
(() => {
  const CONFIG = window.LOCKEDIN_CONFIG;
  const STAT_COLORS = ["#F94144", "#90BE6D", "#3498DB", "#43AA8B", "#F9C74F", "#9B5DE5", "#F3722C", "#4CC9F0"];
  const PLAYER_COLORS = ["#E63946", "#4CC9F0", "#90BE6D", "#F9C74F", "#9B5DE5", "#F3722C", "#43AA8B", "#F15BB5", "#577590", "#FFD6A5"];
  const $ = (id) => document.getElementById(id);

  // ---------- Entitlements ----------
  // PROTOTYPE ONLY: Pro status lives in localStorage, so it is not secure.
  // Replace isPro() with a check against your auth/billing backend before launch.
  // Visit ?pro=1 to simulate Pro, ?pro=0 to go back to free.
  const params = new URLSearchParams(location.search);
  if (params.has("pro")) store("pro", params.get("pro") === "1");
  const isPro = () => load("pro", false) === true;
  const sportConfig = (id = state.sport) => CONFIG.sports.find((s) => s.id === id);
  const limits = () => ({
    maxGames: isPro() ? sportConfig().seasonGames || 82 : CONFIG.free.maxGames,
    teamCompare: isPro() || CONFIG.free.teamCompare,
    props: isPro() || CONFIG.free.props,
    csvExport: isPro() || CONFIG.free.csvExport,
    picks: isPro() || CONFIG.free.picks,
    sportAllowed: (id) => isPro() || CONFIG.free.sports.includes(id),
  });

  function store(key, value) {
    try { localStorage.setItem(`li_${key}`, JSON.stringify(value)); } catch (_) { /* storage unavailable */ }
  }
  function load(key, fallback) {
    try {
      const raw = localStorage.getItem(`li_${key}`);
      return raw === null ? fallback : JSON.parse(raw);
    } catch (_) {
      return fallback;
    }
  }

  // ---------- State ----------
  const saved = load("state", {});
  const firstSport = CONFIG.sports.find((s) => s.enabled).id;
  const state = {
    sport: CONFIG.sports.some((s) => s.enabled && s.id === saved.sport) ? saved.sport : firstSport,
    team: saved.team || null,
    player: saved.player || null,
    group: saved.group || null,
    mode: "player",
    stats: null,
    teamStat: null,
    topN: 5,
    games: 10,
    avgLines: false,
    cumulative: false,
    prop: { stat: null, line: null, side: "Over", key: null },
  };
  const cache = { meta: {}, teams: {} };
  let picks = null;

  const fetchJSON = (path) => fetch(path).then((r) => {
    if (!r.ok) throw new Error(`${path}: ${r.status}`);
    return r.json();
  });

  async function getMeta(sport) {
    cache.meta[sport] ||= await fetchJSON(`data/${sport}/meta.json`);
    return cache.meta[sport];
  }

  async function getTeam(sport, team) {
    const key = `${sport}/${team}`;
    if (!cache.teams[key]) {
      const data = await fetchJSON(`data/${sport}/teams/${team}.json`);
      cache.teams[key] = data.rows.map((row) => ({ ...row, Date: new Date(`${row.Date}T12:00:00`) }));
    }
    return cache.teams[key];
  }

  function persist() {
    store("state", { sport: state.sport, team: state.team, player: state.player, group: state.group });
  }

  // ---------- Sport metadata helpers ----------
  // Groups split a sport's rows by role (MLB Batting vs Pitching); other sports have one implicit group.
  const meta = () => cache.meta[state.sport];
  const currentGroup = () => (meta().groups || []).find((g) => g.id === state.group) || null;
  const availableStats = () => (currentGroup() ? currentGroup().stats : meta().stats);
  const statLabel = (stat) => (currentGroup()?.labels || {})[stat] || meta().stat_labels[stat] || stat;
  const isRate = (stat) => (meta().rate_stats || []).includes(stat);
  const statColor = (stat) => STAT_COLORS[meta().stats.indexOf(stat) % STAT_COLORS.length];

  function teamRows() {
    const rows = cache.teams[`${state.sport}/${state.team}`] || [];
    return currentGroup() ? rows.filter((r) => r.Status === state.group) : rows;
  }

  // ---------- Paywall ----------
  function openPaywall(reason) {
    $("paywall-reason").textContent = reason || "";
    const button = $("checkout-button");
    if (CONFIG.stripePaymentLink) {
      button.textContent = `Upgrade for ${CONFIG.pro.priceLabel}`;
      button.disabled = false;
      $("checkout-note").textContent = "Secure checkout by Stripe. Cancel anytime.";
    } else {
      button.textContent = "Pro is coming soon";
      button.disabled = true;
      $("checkout-note").textContent = "";
    }
    $("paywall").showModal();
  }

  $("checkout-button").addEventListener("click", () => {
    if (CONFIG.stripePaymentLink) location.href = CONFIG.stripePaymentLink;
  });

  $("pro-button").addEventListener("click", () => {
    if (!isPro()) openPaywall();
  });

  function applyProUI() {
    document.body.classList.toggle("is-pro", isPro());
    const button = $("pro-button");
    button.textContent = isPro() ? "PRO" : "Go Pro";
    button.classList.toggle("is-pro", isPro());
  }

  // ---------- Controls ----------
  function renderSportTabs() {
    const nav = $("sport-tabs");
    nav.innerHTML = "";
    for (const sport of CONFIG.sports) {
      const button = document.createElement("button");
      button.type = "button";
      button.textContent = sport.label;
      button.classList.toggle("active", sport.id === state.sport);
      if (!sport.enabled) {
        button.disabled = true;
        button.insertAdjacentHTML("beforeend", "<small>soon</small>");
      } else if (!limits().sportAllowed(sport.id)) {
        button.insertAdjacentHTML("beforeend", ' <span class="lock">PRO</span>');
      }
      button.addEventListener("click", () => {
        if (!limits().sportAllowed(sport.id)) return openPaywall(`${sport.label} is a Pro feature.`);
        if (sport.id === state.sport) return;
        state.sport = sport.id;
        state.team = state.player = state.group = state.stats = state.teamStat = state.prop.stat = null;
        renderSportTabs();
        loadSport();
      });
      nav.appendChild(button);
    }
    const { accent = "#E63946", accentText } = sportConfig();
    document.documentElement.style.setProperty("--accent", accent);
    document.documentElement.style.setProperty("--accent-text", accentText || accent);
  }

  function fillSelect(select, values, selected, labels = {}) {
    select.innerHTML = values.map((v) => `<option value="${escapeHTML(v)}">${escapeHTML(labels[v] || v)}</option>`).join("");
    select.value = values.includes(selected) ? selected : values[0] ?? "";
    return select.value;
  }

  // Reset stat selections that don't exist in the current sport/group.
  function syncStatState() {
    const stats = availableStats();
    state.stats = (state.stats || []).filter((s) => stats.includes(s));
    if (state.stats.length === 0) state.stats = [...stats];
    if (!stats.includes(state.teamStat)) state.teamStat = stats[0];
    const propLabels = Object.fromEntries(stats.map((s) => [s, statLabel(s)]));
    state.prop.stat = fillSelect($("prop-stat"), stats, state.prop.stat, propLabels);
  }

  function renderStatChips() {
    const wrap = $("stat-chips");
    wrap.innerHTML = "";
    const stats = availableStats();
    for (const stat of stats) {
      const chip = document.createElement("button");
      chip.type = "button";
      chip.className = "chip";
      chip.style.setProperty("--chip-color", statColor(stat));
      chip.textContent = statLabel(stat);
      const active = state.mode === "team" ? state.teamStat === stat : state.stats.includes(stat);
      chip.classList.toggle("active", active);
      chip.addEventListener("click", () => {
        if (state.mode === "team") {
          state.teamStat = stat;
        } else if (state.stats.includes(stat)) {
          if (state.stats.length > 1) state.stats = state.stats.filter((s) => s !== stat);
        } else {
          state.stats = stats.filter((s) => s === stat || state.stats.includes(s));
        }
        renderStatChips();
        render();
      });
      wrap.appendChild(chip);
    }
  }

  function applyGameLimit() {
    const slider = $("games");
    const max = limits().maxGames;
    slider.max = max;
    state.games = Math.min(state.games, max);
    slider.value = state.games;
    $("games-value").textContent = state.games;
    $("games-lock").classList.toggle("hidden", isPro());
  }

  function setMode(mode) {
    if (mode === "team" && !limits().teamCompare) return openPaywall("Team Compare is a Pro feature.");
    state.mode = mode;
    document.querySelectorAll(".segmented[aria-label=View] button").forEach((b) => b.classList.toggle("active", b.dataset.mode === mode));
    $("player-field").classList.toggle("hidden", mode === "team");
    $("topn-field").classList.toggle("hidden", mode !== "team");
    $("prop-controls").classList.toggle("hidden", mode === "team");
    renderStatChips();
    render();
  }

  document.querySelectorAll(".segmented[aria-label=View] button").forEach((b) => b.addEventListener("click", () => setMode(b.dataset.mode)));

  $("team-select").addEventListener("change", async (e) => {
    state.team = e.target.value;
    state.player = null;
    await populatePlayers();
    persist();
    render();
  });
  $("group-select").addEventListener("change", async (e) => {
    state.group = e.target.value;
    state.player = state.stats = null;
    syncStatState();
    await populatePlayers();
    renderStatChips();
    persist();
    render();
  });
  $("player-select").addEventListener("change", (e) => {
    state.player = e.target.value;
    persist();
    render();
  });
  $("games").addEventListener("input", (e) => {
    state.games = Number(e.target.value);
    $("games-value").textContent = state.games;
    render();
  });
  $("topn").addEventListener("input", (e) => {
    state.topN = Number(e.target.value);
    $("topn-value").textContent = state.topN;
    render();
  });
  $("avg-lines").addEventListener("change", (e) => { state.avgLines = e.target.checked; render(); });
  $("cumulative").addEventListener("change", (e) => { state.cumulative = e.target.checked; render(); });
  $("csv-button").addEventListener("click", () => {
    if (!limits().csvExport) return openPaywall("CSV export is a Pro feature.");
    downloadCSV();
  });

  // Prop controls: free users see them but any interaction opens the paywall.
  $("prop-controls").addEventListener("pointerdown", (e) => {
    if (limits().props) return;
    e.preventDefault();
    openPaywall("Prop Hit Rate is a Pro feature.");
  });
  $("prop-stat").addEventListener("change", (e) => { state.prop.stat = e.target.value; render(); });
  $("prop-line").addEventListener("input", (e) => {
    const value = parseFloat(e.target.value);
    if (!Number.isNaN(value)) { state.prop.line = value; render(); }
  });
  document.querySelectorAll("#prop-side button").forEach((b) => b.addEventListener("click", () => {
    state.prop.side = b.dataset.side;
    document.querySelectorAll("#prop-side button").forEach((x) => x.classList.toggle("active", x === b));
    render();
  }));

  async function populatePlayers() {
    await getTeam(state.sport, state.team);
    const players = [...new Set(teamRows().map((r) => r.Player))].sort();
    state.player = fillSelect($("player-select"), players, state.player);
  }

  // ---------- Data shaping (mirrors filtered_data() in the Shiny apps) ----------
  function lastGames(rows, n) {
    return [...rows].sort((a, b) => b.Date - a.Date).slice(0, n).sort((a, b) => a.Date - b.Date);
  }

  function mean(values) {
    const nums = values.filter((v) => typeof v === "number" && !Number.isNaN(v));
    return nums.length ? nums.reduce((a, b) => a + b, 0) / nums.length : NaN;
  }

  // Rate stats (AVG, ERA) are already season-to-date figures, so they are never summed.
  function cumulative(rows, stats) {
    const summed = stats.filter((s) => !isRate(s));
    const totals = Object.fromEntries(summed.map((s) => [s, 0]));
    return rows.map((row) => {
      const next = { ...row };
      for (const s of summed) next[s] = totals[s] += row[s] ?? 0;
      return next;
    });
  }

  function playerGames() {
    return lastGames(teamRows().filter((r) => r.Player === state.player), state.games);
  }

  function teamView() {
    const stat = state.teamStat;
    const byPlayer = new Map();
    for (const row of teamRows()) {
      if (!byPlayer.has(row.Player)) byPlayer.set(row.Player, []);
      byPlayer.get(row.Player).push(row);
    }
    const ranked = [...byPlayer.entries()]
      .map(([player, games]) => {
        const recent = lastGames(games, state.games);
        return { player, games: recent, avg: mean(recent.map((g) => g[stat])) };
      })
      .filter((p) => !Number.isNaN(p.avg))
      .sort((a, b) => b.avg - a.avg || a.player.localeCompare(b.player))
      .slice(0, state.topN);
    if (state.cumulative) ranked.forEach((p) => { p.games = cumulative(p.games, [stat]); });
    return ranked;
  }

  // ---------- Rendering ----------
  const fmtDate = (d) => d.toLocaleDateString(undefined, { month: "short", day: "numeric" });
  const fmtStat = (stat, v) => {
    if (typeof v !== "number" || Number.isNaN(v)) return "–";
    if (stat === "AVG") return v.toFixed(3).replace(/^0/, "");
    return isRate(stat) ? v.toFixed(2) : (Math.round(v * 10) / 10).toFixed(1);
  };

  function baseLayout(compact) {
    return {
      paper_bgcolor: "#1e1e1e",
      plot_bgcolor: "#1e1e1e",
      font: { family: "Oswald, sans-serif", color: "#fff" },
      margin: { l: 44, r: 12, t: 12, b: compact ? 90 : 60 },
      hovermode: state.mode === "team" ? "closest" : "x unified",
      hoverlabel: { bgcolor: "#121212", font: { color: "#fff" } },
      xaxis: { type: "date", tickformat: "%b %d", gridcolor: "rgba(255,255,255,0.12)", zeroline: false },
      yaxis: { gridcolor: "rgba(255,255,255,0.12)", zeroline: false, rangemode: "tozero" },
      legend: { orientation: "h", x: 0, y: -0.18, yanchor: "top", font: { size: 12 } },
      showlegend: true,
    };
  }

  function avgShape(x0, x1, y, color) {
    return { type: "line", xref: "x", x0, x1, y0: y, y1: y, line: { color, width: 1.5, dash: "dot" } };
  }

  function render() {
    if (!meta() || !cache.teams[`${state.sport}/${state.team}`]) return;

    const layout = baseLayout(window.innerWidth < 600);
    const traces = [];
    const shapes = [];
    let tableHead = [];
    let tableRows = [];
    let averagesHTML = "";

    if (state.mode === "team") {
      const stat = state.teamStat;
      const ranked = teamView();
      const allDates = ranked.flatMap((p) => p.games.map((g) => g.Date));
      const [x0, x1] = [new Date(Math.min(...allDates)), new Date(Math.max(...allDates))];
      ranked.forEach((p, i) => {
        const color = PLAYER_COLORS[i % PLAYER_COLORS.length];
        traces.push({
          x: p.games.map((g) => g.Date),
          y: p.games.map((g) => g[stat]),
          customdata: p.games.map((g) => g.Opp),
          type: "scatter",
          mode: "lines+markers",
          name: `${i + 1}. ${p.player}`,
          line: { color, width: 3 },
          marker: { color, size: 7 },
          hovertemplate: `<b>${escapeHTML(p.player)}</b><br>%{x|%b %d} %{customdata}<br>${stat}: %{y}<extra></extra>`,
        });
        if (state.avgLines && !state.cumulative) shapes.push(avgShape(x0, x1, p.avg, color));
      });
      $("chart-title").textContent = `${state.team} · ${statLabel(stat)} · last ${state.games} games`;
      averagesHTML = ranked.map((p, i) =>
        `<span style="color:${PLAYER_COLORS[i % PLAYER_COLORS.length]}">${escapeHTML(p.player)}: ${fmtStat(stat, p.avg)}</span>`).join("");
      tableHead = ["Player", "Date", "Opp", stat];
      tableRows = ranked.flatMap((p) => [...p.games].reverse().map((g) => [g.Player, g.Date, g.Opp, g[stat]]));
    } else {
      const raw = playerGames();
      const games = state.cumulative ? cumulative(raw, state.stats) : raw;
      const x = games.map((g) => g.Date);
      for (const stat of state.stats) {
        const color = statColor(stat);
        traces.push({
          x,
          y: games.map((g) => g[stat]),
          customdata: games.map((g) => g.Opp),
          type: "scatter",
          mode: "lines+markers",
          name: statLabel(stat),
          line: { color, width: 3 },
          marker: { color, size: 8 },
          hovertemplate: `${stat}: %{y} (%{customdata})<extra></extra>`,
        });
        if (state.avgLines && !state.cumulative && x.length) {
          shapes.push(avgShape(x[0], x[x.length - 1], mean(raw.map((g) => g[stat])), color));
        }
      }
      $("chart-title").textContent = `Now viewing: ${state.player}`;
      averagesHTML = state.stats.map((stat) =>
        `<span style="color:${statColor(stat)}">Avg ${stat}: ${fmtStat(stat, mean(raw.map((g) => g[stat])))}</span>`).join("");
      tableHead = ["Date", "Opp", ...state.stats];
      tableRows = [...games].reverse().map((g) => [g.Date, g.Opp, ...state.stats.map((s) => g[s])]);
    }

    layout.shapes = shapes;
    Plotly.react("chart", traces, layout, { displayModeBar: false, responsive: true });
    $("averages").innerHTML = averagesHTML;
    renderTable(tableHead, tableRows);
    renderProp();
    state.lastTable = { head: tableHead, rows: tableRows };
  }

  // Mirrors the NBA app's "Prop Hit Rate Analyzer": hits over/under a line in the last N games.
  function renderProp() {
    const box = $("prop-box");
    box.classList.toggle("hidden", state.mode === "team" || !state.player);
    if (state.mode === "team" || !state.player) return;

    const stat = state.prop.stat;
    const seasonValues = teamRows().filter((r) => r.Player === state.player).map((r) => r[stat]);
    // Default the line to the player's season average (nearest 0.5) whenever player or stat changes.
    const key = [state.sport, state.group, state.player, stat].join("|");
    if (state.prop.key !== key) {
      state.prop.key = key;
      const avg = mean(seasonValues);
      state.prop.line = Number.isNaN(avg) ? 0.5 : Math.round(avg * 2) / 2;
    }
    $("prop-line").value = state.prop.line;

    if (!limits().props) {
      box.style.removeProperty("--prop-color");
      box.innerHTML = `<div class="prop-title">Prop Hit Rate</div>
        <div class="prop-rate">See how often ${escapeHTML(state.player)} clears any line. <button type="button">Unlock with Pro</button></div>`;
      box.querySelector("button").addEventListener("click", () => openPaywall("Prop Hit Rate is a Pro feature."));
      return;
    }

    const values = playerGames().map((g) => g[stat]).filter((v) => typeof v === "number");
    const line = state.prop.line;
    const hits = values.filter((v) => (state.prop.side === "Over" ? v > line : v < line)).length;
    const pct = values.length ? Math.round((hits / values.length) * 1000) / 10 : 0;
    box.style.setProperty("--prop-color", pct >= 70 ? "#43AA8B" : pct >= 50 ? "#F8961E" : "#F94144");
    box.innerHTML = `<div class="prop-title">${escapeHTML(state.player)} ${state.prop.side} ${line} ${escapeHTML(stat)}</div>
      <div class="prop-rate">Hit rate (last ${values.length} games): ${hits}/${values.length} (${pct}%)</div>`;
  }

  function renderTable(head, rows) {
    const isNum = (v) => typeof v === "number";
    const headHTML = `<thead><tr>${head.map((h, i) =>
      `<th class="${rows[0] && isNum(rows[0][i]) ? "num" : ""}">${escapeHTML(h)}</th>`).join("")}</tr></thead>`;
    const bodyHTML = rows.map((r) => `<tr>${r.map((v) => {
      const text = v instanceof Date ? fmtDate(v) : v ?? "–";
      return `<td class="${isNum(v) ? "num" : ""}">${escapeHTML(String(text))}</td>`;
    }).join("")}</tr>`).join("");
    $("log-table").innerHTML = headHTML + `<tbody>${bodyHTML}</tbody>`;
  }

  function renderPick() {
    const box = $("pick-box");
    const sportLabel = sportConfig().label;
    const pick = picks && picks.picks.find((p) => p.sport === state.sport);
    box.classList.toggle("hidden", !pick);
    if (!pick) return;
    if (!limits().picks) {
      box.innerHTML = `${sportLabel} Daily Pick is ready. <button type="button">Unlock with Pro</button>`;
      box.querySelector("button").addEventListener("click", () => openPaywall("Daily picks are a Pro feature."));
    } else {
      box.textContent = `Locked In Pick: ${pick.text}`;
    }
  }

  function downloadCSV() {
    const { head, rows } = state.lastTable || {};
    if (!head) return;
    const cell = (v) => {
      const text = v instanceof Date ? v.toISOString().slice(0, 10) : String(v ?? "");
      return /[",\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
    };
    const csv = [head, ...rows].map((r) => r.map(cell).join(",")).join("\n");
    const subject = state.mode === "team" ? state.team : state.player;
    const link = document.createElement("a");
    link.href = URL.createObjectURL(new Blob([csv], { type: "text/csv" }));
    link.download = `${state.sport.toUpperCase()}_${subject.replace(/[^A-Za-z0-9]+/g, "_")}_game_log.csv`;
    link.click();
    URL.revokeObjectURL(link.href);
  }

  function escapeHTML(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  }

  // ---------- Boot ----------
  async function loadSport() {
    try {
      const m = await getMeta(state.sport);
      const groups = (m.groups || []).map((g) => g.id);
      $("group-field").classList.toggle("hidden", groups.length === 0);
      state.group = groups.length ? fillSelect($("group-select"), groups, state.group) : null;
      state.team = fillSelect($("team-select"), m.teams.map((t) => t.abbr), state.team);
      syncStatState();
      applyGameLimit();
      await populatePlayers();
      renderStatChips();
      renderPick();
      const updated = new Date(m.updated);
      $("updated").textContent = `Data through ${m.latest_game} · updated ${updated.toLocaleString()}`;
      persist();
      render();
    } catch (err) {
      console.error(err);
      $("chart-title").textContent = "Couldn't load data. Check your connection and try again.";
    }
  }

  let resizeTimer;
  window.addEventListener("resize", () => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(render, 150);
  });

  $("brand-name").textContent = CONFIG.appName;
  if (!limits().sportAllowed(state.sport)) state.sport = CONFIG.free.sports[0];
  applyProUI();
  renderSportTabs();
  fetchJSON("data/picks.json").then((p) => { picks = p; renderPick(); }).catch(() => {});
  loadSport();

  if ("serviceWorker" in navigator) {
    navigator.serviceWorker.register("sw.js").catch((err) => console.warn("Service worker failed", err));
  }
})();
