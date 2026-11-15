/* Drift's catalog. Everything here is made up: the artists, the labels, the
   numbers. The music itself is synthesized by make_audio.py; "audio" is its
   VERSION, so a new version of the music is fetched afresh. routes.py reads
   this file too: keep what follows `window.DRIFT =` plain JSON. */
window.DRIFT = {
  "audio": "1",
  "tracks": {
    "paper-lanterns": {"title": "Paper Lanterns", "artist": "Maren Holt", "album": "Paper Lanterns", "duration": 120.0, "tint": "#e8794a", "plays": "4,812,306", "released": "September 26, 2026", "label": "Lantern Hall Records"},
    "cedar-and-salt": {"title": "Cedar and Salt", "artist": "The Lindens", "album": "Cedar and Salt", "duration": 117.073, "tint": "#3a9670", "plays": "2,140,977", "released": "September 19, 2026", "label": "Northlight"},
    "linen-hours": {"title": "Linen Hours", "artist": "Odette Vale", "album": "Linen Hours", "duration": 128.0, "tint": "#e48aa0", "plays": "1,306,452", "released": "September 12, 2026", "label": "Odette Vale"},
    "low-tide": {"title": "Low Tide", "artist": "Harbor Club", "album": "Low Tide", "duration": 126.316, "tint": "#3e78b8", "plays": "6,027,118", "released": "September 26, 2026", "label": "Tidewater Sound"},
    "night-ferry": {"title": "Night Ferry", "artist": "Lumen Kid", "album": "Night Ferry", "duration": 114.286, "tint": "#7a5cf0", "plays": "3,384,560", "released": "September 5, 2026", "label": "Afterhours Audio"},
    "moon-pool": {"title": "Moon Pool", "artist": "Small Hours", "album": "Moon Pool", "duration": 116.364, "tint": "#d9479e", "plays": "987,243", "released": "August 29, 2026", "label": "Small Hours"}
  },
  "stations": {
    "morning-fog": {"title": "Morning Fog", "about": "Slow mornings and soft light. Warm pads, gentle plucks, nothing in a hurry.", "tracks": ["paper-lanterns", "cedar-and-salt", "linen-hours"], "tint": "#c58fb0", "followers": "212,480"},
    "night-swim": {"title": "Night Swim", "about": "Deep blue hours. Brushed beats and slow tides for after dark.", "tracks": ["low-tide", "night-ferry", "moon-pool"], "tint": "#2c6aa6", "followers": "389,105"},
    "slow-focus": {"title": "Slow Focus", "about": "Steady, wordless and out of the way. Music for heads-down work.", "tracks": ["cedar-and-salt", "low-tide", "linen-hours"], "tint": "#2b8a6c", "followers": "154,932"},
    "rain-room": {"title": "Rain Room", "about": "Soft weather indoors: pads, drizzle and a lamp left on.", "tracks": ["moon-pool", "paper-lanterns", "night-ferry"], "tint": "#56698f", "followers": "98,761"}
  },
  "mixes": {
    "friday-mix": {"title": "Friday Mix", "about": "Quiet tracks for focus, made from what you played this week.", "tracks": ["paper-lanterns", "low-tide", "cedar-and-salt", "night-ferry", "linen-hours", "moon-pool"], "tint": "#f2685a"},
    "daily-drift-1": {"title": "Daily Drift 1", "about": "Maren Holt, The Lindens, Odette Vale and more", "tracks": ["paper-lanterns", "linen-hours", "cedar-and-salt"], "tint": "#a3a25a"},
    "daily-drift-2": {"title": "Daily Drift 2", "about": "Harbor Club, Lumen Kid, Small Hours and more", "tracks": ["night-ferry", "low-tide", "moon-pool"], "tint": "#2f6fc0"},
    "on-repeat": {"title": "On Repeat", "about": "The ones you keep coming back to.", "tracks": ["low-tide", "paper-lanterns", "moon-pool", "cedar-and-salt"], "tint": "#a83fa6"},
    "slow-sunday": {"title": "Slow Sunday", "about": "Unhurried music for a long breakfast.", "tracks": ["linen-hours", "paper-lanterns", "cedar-and-salt"], "tint": "#d98f78"}
  },
  "home": {
    "quick": ["station:morning-fog", "station:night-swim", "mix:friday-mix", "album:low-tide", "mix:daily-drift-1", "station:slow-focus"],
    "featured": ["morning-fog", "night-swim"],
    "made_for": ["friday-mix", "daily-drift-1", "daily-drift-2", "on-repeat", "slow-sunday"],
    "releases": ["paper-lanterns", "low-tide", "cedar-and-salt", "linen-hours", "night-ferry", "moon-pool"]
  },
  "liked": ["low-tide", "paper-lanterns", "night-ferry"]
};
