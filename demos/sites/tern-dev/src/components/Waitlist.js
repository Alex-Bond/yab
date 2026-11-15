import { api } from '../lib/api.js';
import { toast } from '../lib/toast.js';

// Until 2.0 ships, every "Start free" puts the team on the early list.
export function mountStartButtons(root = document) {
  root.addEventListener('click', async (event) => {
    const button = event.target.closest('[data-start]');
    if (!button) return;
    event.preventDefault();
    if (button.getAttribute('aria-busy') === 'true') return;

    button.setAttribute('aria-busy', 'true');
    try {
      await api('/waitlist', {
        method: 'POST',
        body: { plan: button.dataset.plan ?? 'free', source: button.dataset.start, referrer: document.referrer || null },
      });
      window.location.assign('/welcome');
    } catch (error) {
      console.error(`Waitlist signup failed: ${error.message}`, error.body?.error?.message ?? '');
      toast({
        title: 'Something went wrong',
        text: "We couldn't save your spot just now. Please try again in a minute.",
      });
    } finally {
      button.removeAttribute('aria-busy');
    }
  });
}
