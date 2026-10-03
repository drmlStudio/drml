import { defineConfig } from 'vitest/config';

/** Fast JavaScript-only tests; CLI process tests live in vitest.integration.config.ts. */
export default defineConfig({
  test: {
    include: ['tests/unit/**/*.test.ts'],
    exclude: ['tests/integration/**'],
  },
});
