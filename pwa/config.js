// App-wide settings. Edit these instead of touching app.js.
window.LOCKEDIN_CONFIG = {
  appName: "Locked In Analytics",

  // accent colors borders and buttons; optional accentText is a lighter shade for labels on dark accents.
  // Sports appear as tabs. Data comes from pipeline/<id>.R → data/<id>/.
  sports: [
    { id: "nba", label: "NBA", enabled: true, accent: "#E63946", seasonGames: 82 },
    { id: "wnba", label: "WNBA", enabled: false, accent: "#E8590C", seasonGames: 44 },
    { id: "mlb", label: "MLB", enabled: false, accent: "#1F3C88", accentText: "#7C9BE6", seasonGames: 162 },
  ],

  // Free vs Pro limits.
  free: {
    maxGames: 10,
    sports: ["nba", "wnba", "mlb"], // sports free users can open (once enabled above)
    teamCompare: false,
    props: false,                   // Prop Hit Rate analyzer
    csvExport: false,
    picks: false,
  },
  pro: {
    // Pro game limit is each sport's seasonGames above.
    priceLabel: "$4.99/mo",
  },

  // Paste your Stripe Payment Link here (Stripe Dashboard → Payment Links).
  // Leave empty to show a "coming soon" message instead.
  stripePaymentLink: "",
};
