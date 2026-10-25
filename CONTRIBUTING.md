# Contributing to OpenRead

Help make reading easier for more people. Bug reports, documentation improvements,
accessibility feedback, browser fixes and model integrations are welcome.
You do not need to donate to contribute or use OpenRead.

## Suggest a change

Search [existing issues](https://github.com/ahmednajaf/openread/issues) first.
For a bug, include your OS/browser version, setup steps, expected behaviour and
what happened. A small public test article helps with reading/highlighting bugs.
Remove private document text, recordings, account details and other personal data.
Discuss substantial features in an issue before investing time in a large change.

## Send a pull request

1. Fork the repository and make a branch for one focused change.
2. Follow [GETTING_STARTED.md](GETTING_STARTED.md) for local setup. For source
   development, use Node 22+ and Python 3.11–3.13.
3. Run `npm ci`, `npm run build` and `npm test`. Include relevant browser/model
   checks when changing playback or a local integration; the development guide lists them.
4. Explain the problem, the resulting behaviour and how you checked it. Include
   screenshots for visual changes and the browser tested for extension changes.
5. Open a pull request. Ahmed (@ahmednajaf) reviews changes and decides whether to
   request revisions, merge or close them. Submission does not guarantee acceptance.

Keep appearance tied to the device settings and preserve Safari's native toolbar
surface. Keep processing local by default, request browser permissions only when
needed, and avoid paywalls or hosted-service requirements for existing features.
Do not commit model weights, environments, saved readings, recordings or secrets.

## Licensing

By submitting a contribution, you agree to license your original contribution
under GPL-3.0-or-later, as described in [LICENSING.md](LICENSING.md). Retain your
copyright and upstream notices. Only submit material you have the right to
contribute. Identify third-party adaptations and their licences in your PR and
update THIRD_PARTY.md when adding dependencies or models. Do not add voices with
unclear redistribution or voice rights.

Be respectful and constructive. Accessibility experiences vary; reports from
people who use the tool matter as much as code contributions.
