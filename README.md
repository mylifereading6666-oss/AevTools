# AevTools

AevTools is a responsive browser-based productivity toolkit for mobile, tablet, and desktop.

## Main modules
- **AevTask** — tasks, due dates, priorities, completion status
- **AevTools** — character count, QR generation, image resizing, JSON formatting, password generation
- **AevFocus** — focus/break timer, study records, daily goals
- **AevMoney** — income/expense records, categories, monthly budget tracking
- **AevMemo** — notes, tags, search, favorites
- **Shared account/profile** — Supabase-backed authentication and profile shared with AevNetwork

## Use
Open the deployed [AevTools website](https://mylifereading6666-oss.github.io/AevTools/). Use the three-line menu to switch modules. Sign in or register to use account-based features. Nickname changes are limited to once per 14 days; other profile settings can be edited separately.

## Documentation
- [Privacy Policy](privacy-policy.html)
- [Terms of Use](terms.html)
- [Specifications and User Guide](guide.html)
- [MIT License](LICENSE)

## Data and privacy
Some utility records and preferences are stored in browser storage and may not sync between browsers/devices. Shared account and profile data are handled through Supabase. Clearing site data may remove local records or the saved login state. Email report links only open the user's configured email app with a prefilled draft; the user reviews and sends it. External QR generation and Google/YouTube features may involve third-party services.

## Development and deployment
This is a static-first website hosted with GitHub Pages. Open `index.html` for a local preview where supported. Configure GitHub Pages to use the repository's Actions workflow as documented in repository settings.

## Related service
[AevNetwork](https://mylifereading6666-oss.github.io/AevNetwork/) shares the account/profile system. Each service maintains its own announcements and service-specific features.
