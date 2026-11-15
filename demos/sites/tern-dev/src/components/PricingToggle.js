import { formatPrice, loadPlans } from './Plans.js';

// Monthly or yearly: the plans read their prices again from the API, and
// fall back to the ones written in the page.
export function mountPricingToggle(root) {
  if (!root) return;
  const options = [...root.querySelectorAll('[data-period]')];
  const plans = document.querySelector('[data-plans]');

  async function choose(period) {
    for (const option of options) option.setAttribute('aria-pressed', String(option.dataset.period === period));
    root.dataset.period = period;
    if (plans) plans.dataset.period = period;

    const list = await loadPlans().catch(() => null);
    for (const el of document.querySelectorAll('[data-plan-price]')) {
      const plan = list?.find((p) => p.id === el.dataset.planPrice);
      el.textContent = plan ? formatPrice(plan.price[period]) : el.dataset[period];
    }
    for (const el of document.querySelectorAll('[data-billing-note]')) {
      el.textContent = el.dataset[period];
    }
  }

  for (const option of options) option.addEventListener('click', () => choose(option.dataset.period));
  choose(root.dataset.period ?? 'monthly');
}
