// The small pill beside a footer link: "We're hiring" on Careers. Links ask
// for one with data-badge="<name>". (The header's are in the HTML, so the
// nav doesn't shift once this runs.)

export const BADGES = {
  careers: { label: "We're hiring", tone: 'sage' },
  changelog: { label: 'New', tone: 'coral' },
};

export function renderBadge(badge) {
  const label = badge.label;
  const el = document.createElement('span');
  el.className = 'badge';
  el.dataset.tone = badge.tone ?? 'neutral';
  el.textContent = label;
  return el;
}

export function mountBadges(root = document) {
  for (const link of root.querySelectorAll('[data-badge]')) {
    link.append(renderBadge(BADGES[link.dataset.badge]));
  }
}
