// The site's language. A language link, or the footer's menu, keeps the
// choice under the app's own name for it (app/lib/l10n/l10n.dart), so the
// game follows it too.
// With nothing chosen, an English page sends a visitor whose browser
// prefers one of the others to that one, as the app does with a device's
// language. A page in another language is never left: its address was
// asked for.
(() => {
  const KEY = 'flutter.language';
  const others = ['es', 'pt', 'de', 'fr'];
  const here = document.documentElement.lang.slice(0, 2);

  let chosen = null;
  try {
    chosen = JSON.parse(localStorage.getItem(KEY));
  } catch {}

  if (here === 'en') {
    const wanted = chosen ?? (navigator.languages || [navigator.language])
      .map((l) => l.slice(0, 2).toLowerCase())
      .find((l) => l === 'en' || others.includes(l));
    if (others.includes(wanted)) {
      location.replace(`/${wanted}${location.pathname}${location.search}${location.hash}`);
    }
  }

  const keep = (lang) => {
    try {
      localStorage.setItem(KEY, JSON.stringify(lang.slice(0, 2)));
    } catch {}
  };
  document.addEventListener('click', (e) => {
    const link = e.target.closest('a[hreflang]');
    if (link) keep(link.hreflang);
  });
  // The footer's menu: the same choice, then the page in that language.
  document.addEventListener('change', (e) => {
    const pick = e.target.closest('select.lang-pick');
    if (!pick) return;
    const option = pick.selectedOptions[0];
    keep(option.lang);
    location.href = option.value;
  });
})();
