import { api } from '../lib/api.js';
import { h } from '../lib/dom.js';

const TONES = ['sage', 'lilac', 'sand'];

function initials(name) {
  return name
    .split(' ')
    .map((part) => part[0])
    .join('')
    .slice(0, 2);
}

function Quote(item, index) {
  return h('figure', { class: 'card quote', key: item.id }, [
    h('blockquote', {}, `“${item.quote}”`),
    h('figcaption', {}, [
      h('span', { class: `avatar avatar--${TONES[index % TONES.length]}` }, initials(item.name)),
      h('span', {}, [h('strong', {}, item.name), h('span', {}, `${item.role}, ${item.company}`)]),
    ]),
  ]);
}

// Fresh quotes from the CMS. The three in the page stay when it can't answer.
export async function loadTestimonials(root) {
  if (!root) return;
  try {
    const items = await api('/testimonials');
    root.replaceChildren(...items.map(Quote));
  } catch (error) {
    console.error(`Failed to load testimonials: ${error.message}`);
  }
}
