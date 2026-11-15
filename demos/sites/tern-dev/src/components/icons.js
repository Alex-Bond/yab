// Feature icons: 24 px grid, 1.75 stroke, round ends.

const open = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">';

const paths = {
  shield: '<path d="M12 3.5 5 6.2v5.3c0 4.3 3 7.4 7 9 4-1.6 7-4.7 7-9V6.2L12 3.5Z"/><path d="M12 8.5V12l2.2 1.6"/>',
  sparkle:
    '<path d="M12 4.5 13.6 9a2 2 0 0 0 1.4 1.4l4.5 1.6-4.5 1.6a2 2 0 0 0-1.4 1.4L12 19.5 10.4 15A2 2 0 0 0 9 13.6L4.5 12 9 10.4A2 2 0 0 0 10.4 9Z"/><path d="M19 3.5v3M17.5 5h3"/>',
  buffer:
    '<rect x="4" y="3.5" width="16" height="5.5" rx="2"/><rect x="4" y="15" width="16" height="5.5" rx="2"/><path d="M12 10.75v2.5"/>',
  globe:
    '<circle cx="12" cy="12" r="8.5"/><path d="M3.5 12h17M12 3.5c2.3 2.3 3.5 5.1 3.5 8.5s-1.2 6.2-3.5 8.5c-2.3-2.3-3.5-5.1-3.5-8.5S9.7 5.8 12 3.5Z"/>',
  sun: '<circle cx="12" cy="12" r="3.75"/><path d="M12 3v2M12 19v2M3 12h2M19 12h2M5.6 5.6 7 7M17 17l1.4 1.4M5.6 18.4 7 17M17 7l1.4-1.4"/>',
  chart:
    '<path d="M4 20h16"/><rect x="5.5" y="11" width="3" height="6" rx="1"/><rect x="10.5" y="7" width="3" height="10" rx="1"/><rect x="15.5" y="13" width="3" height="4" rx="1"/>',
};

export function icon(name) {
  return open + (paths[name] ?? '') + '</svg>';
}
