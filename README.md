# AevTools

AevTools is a responsive, browser-based Japanese productivity toolkit that brings five tools together:

- **AevTask** — task list, due dates, priority, and completion checkboxes
- **AevTools** — character counter, QR code creation, image resizing, JSON formatting, and password generation
- **AevFocus** — Pomodoro timer, study-time logs, and daily goals
- **AevMoney** — allowance income/expense tracking, category labels, and monthly budget
- **AevMemo** — notes, tags, search, and favorites

## Use the site

Open the deployed site and use the ☰ menu to switch between sections. The home page includes tool introductions, a getting-started guide, and a field for your YouTube channel URL.

## Run locally

Download or clone the repository, then open `index.html` in a modern browser. No build step or server is required.

## GitHub Pages

This repository includes a GitHub Actions workflow at `.github/workflows/pages.yml`.

1. Open **Settings → Pages** in the repository.
2. Under **Build and deployment → Source**, select **GitHub Actions**.
3. Push to `main` or manually run **Deploy AevTools to GitHub Pages** from the Actions tab.
4. After the workflow succeeds, open the Pages URL shown in the deployment.

## Data and privacy

Task, study, money, memo, and YouTube URL settings are stored in the browser's local storage. They are not synchronized between devices or browsers. Clearing browser data may remove them. Do not store sensitive information.

QR generation loads an external QR service, and the YouTube link opens the URL you enter. Avoid entering private data into QR content.

## License

This project is intended to use the **MIT License**. See [LICENSE](LICENSE). Third-party services and libraries retain their own terms.
