---
name: visualize
description: Present comparisons, charts and interactive explanations in Yab chat using the connected agent's visualization capability.
sites: []
keywords: [visualize, visualization, interactive chart, diagram, сравни варианты, визуализация, диаграмма, интерактивный график]
---

# Visual explanations

Use a visual when it makes the answer clearer: comparisons, timelines, diagrams and exploration.
Embed the evidence already gathered, link its sources and label assumptions or approximate values.
For a short mapping, use a Markdown table; do not build a widget for a single fact.

Yab renders supported Claude show_widget output and Codex visualization-file markers in chat.
Use the connected agent's visualization tool or skill when available, following its exact output
contract. Do not invent a show_widget tool, copy another browser's `visual` fence, or fabricate Codex markers.
If the connected agent has no visualization capability, use Markdown or Mermaid when supported.
With Mac access, an HTML file can be offered as a file to open, without claiming it rendered inline.

Match the surrounding light/dark theme, use fluid widths suitable for a narrow chat column, and
make labels readable without hover. Prefer direct labels and a small number of meaningful colors.
Interactive controls should explore the displayed data; actions on websites still use Yab tools
and the user's authorization. Never embed session cookies, credentials or private APIs in a widget.
For an HTML visual, check narrow and wide layouts and script errors using available preview tools.
