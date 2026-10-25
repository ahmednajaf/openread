# Public website

The static landing page is separate from the local reading app. Visitors can play a recorded Kiki voice sample, watch the real app demo, and follow the Mac installation guide. There are no document uploads, analytics, cloud inference calls or connections to a visitor's local helper.

Run `npm run site:dev` from the repository root for the preview at **http://127.0.0.1:4190/**. `npm run site:build` builds `website/dist/`; Vercel serves only that folder. Source lives in `src/`, public media and the privacy notice in `public/`.

The sample text and timings come from the maintainer-supplied Odyssey demonstration. `kiki-sample.m4a` is the actual first two sentences rendered locally with Kitten Mini Kiki; timings are approximate. `openread-demo.mp4` is the 27-second OpenRead 0.4 demonstration. The cover and share card are project artwork. Third-party notices and translation rights are described in [THIRD_PARTY.md](../THIRD_PARTY.md).

The production origin is supplied via `SITE_URL` or `VERCEL_PROJECT_PRODUCTION_URL` when building social metadata and the sitemap. Public install links target the GitHub source ZIP until a store listing is available; do not advertise a store install before it is approved and live.
