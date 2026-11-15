import { api } from '../lib/api.js';

let plans;

// Prices come from the billing service, in cents per seat and month.
export function loadPlans() {
  plans ??= api('/plans').then((data) => data.plans);
  return plans;
}

export function formatPrice(cents) {
  const dollars = cents / 100;
  return Number.isInteger(dollars) ? `$${dollars}` : `$${dollars.toFixed(2)}`;
}

export async function showPlanPrices(period = 'monthly') {
  const list = await loadPlans();
  for (const plan of list) {
    for (const el of document.querySelectorAll(`[data-plan-price="${plan.id}"]`)) {
      el.textContent = formatPrice(plan.price[period]);
    }
  }
  return list;
}

export async function showWaitlistCount() {
  const targets = document.querySelectorAll('[data-waitlist-count]');
  if (!targets.length) return;
  const { count } = await api('/waitlist/count');
  for (const el of targets) el.textContent = count.toLocaleString('en-US');
}
