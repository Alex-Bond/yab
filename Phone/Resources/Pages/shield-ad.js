// The ad script of shield.html, as if from doubleclick.net: when nothing
// blocks it, it puts a sponsor's box in the article.
(function () {
  const slot = document.getElementById('sponsor-slot');
  if (!slot) return;
  const box = document.createElement('div');
  box.className = 'sponsor';
  box.textContent = 'Sponsored: a ferry pass for the whole summer';
  slot.appendChild(box);
})();
