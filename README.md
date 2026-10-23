# ClaudeBook

A GoodNotes-style iPad notebook built on PencilKit, wired straight into the Claude app.
Claude can look at the page you have open, read your handwriting, and draw on top of it.

## How it fits together

```
 Claude app (iPad / phone / web)
        │  custom connector: https://book.clarifiq.in/mcp/<secret>
        ▼
 ClaudeBook server (Oracle box, Docker + Caddy HTTPS)
   • MCP tools: get_current_page, view_page, draw_on_page, erase_my_drawings,
     list_notebooks, create_notebook, add_pages
   • REST + websocket for the iPad app
        ▲
        │  page snapshots + handwriting boxes up, Claude's ink down (live)
 ClaudeBook iPad app (SwiftUI + PencilKit)
```

Every page uses one coordinate space, 1000 x 1414 (A4 ratio), on the server and the app,
so where Claude draws is exactly where it shows up. Claude's ink lives on its own layer
that you can hide, undo or clear without touching your writing.

## Repo layout

- `server/` Node + TypeScript MCP server. `npm run dev` locally, `npm test` runs an end to end MCP check against a running server.
- `deploy/` Docker Compose + Caddy for the Oracle server. GitHub Actions deploys on every push to `main`.
- `ios/` The iPad app. `project.yml` is an XcodeGen spec; GitHub Actions builds an unsigned IPA on a macOS runner.

## One time setup

GitHub repo secrets (Settings > Secrets and variables > Actions):

| Secret | What |
| --- | --- |
| `SERVER_HOST` | Oracle server public IP |
| `SERVER_USER` | SSH user (`ubuntu` or `opc`) |
| `SERVER_SSH_KEY` | Private key that can SSH in |
| `CLAUDEBOOK_SECRET` | Any random string, 32+ chars. Guards the connector URL and the app |

DNS: `book.clarifiq.in` A record to the server IP. Oracle security list: allow TCP 80 and 443.

Then in the Claude app: Settings > Connectors > Add custom connector, URL
`https://book.clarifiq.in/mcp/<CLAUDEBOOK_SECRET>`.

Web viewer for testing without the iPad: `https://book.clarifiq.in/view?token=<CLAUDEBOOK_SECRET>`.

## Installing the iPad app

Download `ClaudeBook-ipa` from the latest "Build iPad app" run in the Actions tab, then
sideload it with Sideloadly (free Apple ID, re-sign every 7 days) or ship it through
TestFlight once an Apple Developer account is set up.
