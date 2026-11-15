import { API_TARGET, BUILD, FLAGS } from './config.js';
import { mountBadges } from './components/Badge.js';
import { FeatureGrid } from './components/FeatureGrid.js';
import { mountHeader } from './components/Header.js';
import { showPlanPrices, showWaitlistCount } from './components/Plans.js';
import { mountPricingToggle } from './components/PricingToggle.js';
import { loadTestimonials } from './components/Testimonials.js';
import { mountStartButtons } from './components/Waitlist.js';
import { features } from './data/features.js';

const enabled = Object.keys(FLAGS).filter((name) => FLAGS[name]);
console.log(`[tern] build ${BUILD}`);
console.info(`[tern] api ${API_TARGET} via the /api proxy · flags: ${enabled.join(', ')}`);

const page = document.body.dataset.page;

mountHeader(document.querySelector('[data-header]'));
mountStartButtons();
showWaitlistCount().catch((error) => console.warn(`[tern] waitlist count unavailable: ${error.message}`));

if (page === 'landing') {
  showPlanPrices().catch((error) => console.warn(`[tern] plans unavailable: ${error.message}`));
  FeatureGrid(document.querySelector('[data-feature-grid]'), features);
  loadTestimonials(document.querySelector('[data-testimonials]'));
}

if (page === 'pricing') {
  mountPricingToggle(document.querySelector('[data-billing-toggle]'));
}

mountBadges();
