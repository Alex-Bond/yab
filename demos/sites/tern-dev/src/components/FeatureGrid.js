import { h, list } from '../lib/dom.js';
import { icon } from './icons.js';

function FeatureCard(feature) {
  return h('article', { class: 'card feature-card' }, [
    h('span', { class: 'feature-card__icon', html: icon(feature.icon) }),
    h('h3', {}, feature.title),
    h('p', {}, feature.body),
  ]);
}

function MoreFeatures(feature) {
  return h('p', { class: 'feature-grid__more' }, [feature.text, ' ', h('a', { href: feature.href }, 'See every feature')]);
}

export function FeatureGrid(root, features) {
  if (!root) return;
  const children = features.map((feature) => (feature.more ? MoreFeatures(feature) : FeatureCard(feature)));
  root.replaceChildren(list(children, 'FeatureGrid'));
}
