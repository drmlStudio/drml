import { defineConfig } from 'vitepress'

export default defineConfig({
  title: 'drml',
  description: 'A fast, explicit package manager for JavaScript and TypeScript projects.',
  lang: 'en-US',
  cleanUrls: true,
  vite: { server: { allowedHosts: true } },
  head: [
    ['link', { rel: 'icon', href: '/logo.svg' }],
    ['meta', { name: 'theme-color', content: '#090a10' }]
  ],
  themeConfig: {
    logo: '/logo-wordmark.svg',
    siteTitle: 'drml',
    nav: [
      { text: 'Guide', link: '/guide/getting-started' },
      { text: 'Commands', link: '/guide/commands' },
      { text: 'GitHub', link: 'https://github.com/drmlStudio/drml', target: '_blank' }
    ],
    sidebar: {
      '/guide/': [
        { text: 'Start here', items: [{ text: 'Getting started', link: '/guide/getting-started' }] },
        { text: 'Reference', items: [{ text: 'Commands', link: '/guide/commands' }, { text: 'Architecture', link: '/guide/architecture' }] }
      ]
    },
    socialLinks: [{ icon: 'github', link: 'https://github.com/drmlStudio/drml' }],
    search: { provider: 'local' },
    footer: { message: 'Built in Zig. Licensed under the MIT License.', copyright: 'Copyright © 2026 drml contributors' },
    outline: 'deep',
    editLink: { pattern: 'https://github.com/drmlStudio/drml/edit/main/website/docs/:path' }
  }
})
