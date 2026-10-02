# drml website

The documentation site combines **VitePress** and **Vue**: VitePress owns routing, Markdown, the default theme, and static generation; Vue single-file components provide reusable UI inside Markdown pages.

```sh
npm install
npm run dev
npm run build
npm run typecheck
```

The site source lives in `docs/`; the generated static output is `docs/.vitepress/dist/`. Vue components registered by the VitePress theme live in `docs/.vitepress/components/`.

```text
website/
├── docs/
│   ├── .vitepress/
│   │   ├── components/   # Vue SFCs used by Markdown pages
│   │   ├── config.ts     # VitePress + Vite configuration
│   │   └── theme.ts      # component registration
│   └── guide/
└── package.json          # Vue, Vite, VitePress, and type-check tooling
```
