import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    environment: 'jsdom',
    environmentOptions: { jsdom: { url: 'https://example.com/login' } },
    include: ['tests/**/*.test.ts'],
  },
});
