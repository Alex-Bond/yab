import { api } from '../lib/api.js';

// The header gets its line once the page scrolls, and says "Open Tern"
// instead of "Sign in" to someone who already is.
export function mountHeader(header) {
  if (!header) return;
  const onScroll = () => header.classList.toggle('is-scrolled', window.scrollY > 8);
  onScroll();
  window.addEventListener('scroll', onScroll, { passive: true });
  checkSession(header);
}

async function checkSession(header) {
  try {
    const session = await api('/session');
    const link = header.querySelector('[data-session]');
    link.textContent = 'Open Tern';
    link.href = '/app';
    link.title = session.user.email;
  } catch (error) {
    if (error.status !== 401) console.warn(`[tern] session check failed: ${error.message}`);
  }
}
