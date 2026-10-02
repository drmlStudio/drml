import DefaultTheme from 'vitepress/theme'
import type { Theme } from 'vitepress'
import CapabilityGrid from './components/CapabilityGrid.vue'
import './theme.css'

const theme: Theme = {
  extends: DefaultTheme,
  enhanceApp({ app }) {
    app.component('CapabilityGrid', CapabilityGrid)
  }
}

export default theme
