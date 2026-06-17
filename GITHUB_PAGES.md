# Deploying to GitHub Pages

This guide shows how to publish the x86 NASM Explorer webapp at
`https://meta-forte.github.io/x86-NASM-SIMD-code/` using GitHub Actions.

---

## How the webapp fetches files

`webapp/index.html` fetches source files and annotations at runtime using
two path constants near the top of the `<script>` block:

```js
const ASM_DIR      = '../src';
const COMMENTS_DIR = '../comments';
```

These paths are relative to the HTML file. For local development (served from
`webapp/`) they resolve correctly. For GitHub Pages the HTML file will be at
the **repo root** of the deployment, so the paths must be changed to:

```js
const ASM_DIR      = 'src';
const COMMENTS_DIR = 'comments';
```

The GitHub Actions workflow below patches these paths automatically — you never
need to change the file by hand.

---

## One-time setup

### 1 · Enable GitHub Pages

1. Go to your repo → **Settings → Pages**.
2. Under **Source**, choose **GitHub Actions**.
3. Save.

### 2 · Create the workflow file

Create `.github/workflows/deploy.yml` with the content below (or copy-paste):

```yaml
name: Deploy to GitHub Pages

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read
  pages: write
  id-token: write

concurrency:
  group: pages
  cancel-in-progress: true

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Build site
        run: |
          mkdir -p _site/src _site/comments
          # Copy source files and annotations
          cp src/*.asm       _site/src/
          cp comments/*.json _site/comments/
          # Copy webapp HTML, fixing fetch paths for the deployed root
          sed 's|../src|src|g; s|../comments|comments|g' \
            webapp/index.html > _site/index.html

      - name: Upload Pages artifact
        uses: actions/upload-pages-artifact@v3
        with:
          path: _site

      - name: Deploy to GitHub Pages
        id: deployment
        uses: actions/deploy-pages@v4
```

Commit and push this file. The first deploy starts automatically.

---

## After deployment

Your live URL will be:

```
https://meta-forte.github.io/x86-NASM-SIMD-code/
```

Every push to `main` triggers a new deploy. Typical build time is under 30 s.

---

## Local preview (no server needed)

The webapp uses `fetch()`, which requires an HTTP server (browsers block
`file://` cross-origin requests). Any of these work:

```bash
# Python 3
python3 -m http.server 8080 --directory .
# then open http://localhost:8080/webapp/

# Node (npx)
npx serve .
# then open http://localhost:3000/webapp/

# VS Code
# Install the "Live Server" extension, right-click webapp/index.html → Open with Live Server
```

---

## Adding new programs

After you add new `.asm` and `.json` files and update the `FILES` array in
`webapp/index.html`, just push to `main`. The workflow picks up all files via
`cp src/*.asm` and `cp comments/*.json` — no extra changes to the workflow.

See `ADD_PROGRAMS_PROMPT.md` for the prompt template to use when asking an AI
assistant to add new programs to this collection.
