/* Runs only when the user chooses OpenRead in Safari's share sheet. */
var ExtensionPreprocessingJS = {
  run: function (args) {
    var selection = String(window.getSelection() || '').trim();
    var article = document.querySelector('article') || document.querySelector('main') || document.body;
    var clone = article.cloneNode(true);
    clone.querySelectorAll('script,style,nav,aside,footer,form,button,[hidden],[aria-hidden=true]').forEach(function (node) { node.remove(); });
    clone.querySelectorAll('p,h1,h2,h3,h4,li,blockquote,br').forEach(function (node) { node.appendChild(document.createTextNode('\n\n')); });
    args.completionFunction({ title: document.title.slice(0, 240), text: (selection || clone.textContent).trim().slice(0, 250001), url: location.href.slice(0, 1000) });
  }
};
