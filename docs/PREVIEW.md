# Isolated development preview

Run `npm ci`, then `npm run design` and open http://127.0.0.1:4180/. This builds the production app from `app/reader/src/` and uses a separate library/helper at port 8767. It does not replace your regular library.

The supplied Glass Headline Hero is attributed under MIT in `docs/notices/GlassHeadlineHero-LICENSE.txt`. Build/runtime notices are documented in `THIRD_PARTY.md`.
