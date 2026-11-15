// One quiet card at the bottom of the page, gone after a few seconds.

const ALERT =
  '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="12" cy="12" r="8.5"/><path d="M12 7.75v4.75"/><circle cx="12" cy="15.9" r=".6" fill="currentColor"/></svg>';
const CLOSE =
  '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M7 7l10 10M17 7 7 17"/></svg>';

let region;

function regionFor() {
  if (!region) {
    region = document.createElement('div');
    region.className = 'toasts';
    region.setAttribute('role', 'status');
    region.setAttribute('aria-live', 'polite');
    document.body.append(region);
  }
  return region;
}

export function toast({ title, text, timeout = 6000 }) {
  const card = document.createElement('div');
  card.className = 'toast';
  card.innerHTML = `
    <span class="toast__icon">${ALERT}</span>
    <div class="toast__body">
      <div class="toast__title"></div>
      <div class="toast__text"></div>
    </div>
    <button class="toast__close" type="button" aria-label="Dismiss">${CLOSE}</button>`;
  card.querySelector('.toast__title').textContent = title;
  card.querySelector('.toast__text').textContent = text;

  const leave = () => {
    if (card.classList.contains('is-leaving')) return;
    card.classList.add('is-leaving');
    card.addEventListener('animationend', () => card.remove(), { once: true });
  };
  card.querySelector('.toast__close').addEventListener('click', leave);
  setTimeout(leave, timeout);

  const host = regionFor();
  host.replaceChildren(card);
  return card;
}
