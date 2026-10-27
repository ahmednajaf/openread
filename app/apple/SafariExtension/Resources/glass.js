/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 Ahmed Najaf and OpenRead contributors.
 * Small DOM adapter; Safari supplies the toolbar's native material.
 */
(() => {
  function enhance(element, button = false) {
    const content = document.createElement('div');
    content.className = button ? 'glass-button-content' : 'glass-content';
    content.append(...element.childNodes);
    element.append(content);
    element.dataset.openreadMaterial = button ? 'control' : 'preview';
    return {
      element,
      destroy() {
        content.replaceWith(...content.childNodes);
        delete element.dataset.openreadMaterial;
      },
    };
  }
  globalThis.OpenReadGlass = { enhance };
})();
