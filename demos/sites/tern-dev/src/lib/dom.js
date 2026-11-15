// h() builds an element; list() puts children together and, like React in
// development, warns about each one that has no key.

export function h(tag, props = {}, children = []) {
  const el = document.createElement(tag);
  for (const [name, value] of Object.entries(props)) {
    if (value == null || value === false) continue;
    if (name === 'class') el.className = value;
    else if (name === 'html') el.innerHTML = value;
    else if (name === 'key') el.dataset.key = value;
    else if (name.startsWith('on')) el.addEventListener(name.slice(2).toLowerCase(), value);
    else el.setAttribute(name, value);
  }
  for (const child of [].concat(children)) {
    if (child == null || child === false) continue;
    el.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return el;
}

export function list(children, owner) {
  const fragment = document.createDocumentFragment();
  for (const child of children) {
    if (child.dataset.key === undefined) {
      console.warn(
        `Warning: Each child in a list should have a unique "key" prop. Check the render method of \`${owner}\`.`,
      );
    }
    fragment.append(child);
  }
  return fragment;
}
