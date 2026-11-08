import tailwindcss from '@tailwindcss/vite';
import { defineConfig, type WxtViteConfig } from 'wxt';
import { STORE_PACKAGE_ENV, extensionManifest } from './manifest';

const storePackage = process.env[STORE_PACKAGE_ENV] === '1';

// Laid out like mkext (https://mkext.dev): entrypoints in src/app, React for extension pages, Tailwind.
export default defineConfig({
  srcDir: 'src',
  entrypointsDir: 'app',
  modules: ['@wxt-dev/module-react'],
  manifestVersion: 3,
  manifest: ({ browser }) => extensionManifest({ browser, storePackage, account: process.env.WXT_PP_STORE !== 'mas' }),
  // Its own build folder, so the store package never replaces the unpacked `.output/chrome-mv3` (which keeps the key).
  outDirTemplate: storePackage ? '{{browser}}-mv{{manifestVersion}}-store' : undefined,
  // `-store` keeps the store package apart from a zip with the key.
  zip: { artifactTemplate: storePackage ? '{{name}}-{{version}}-{{browser}}-store.zip' : '{{name}}-{{version}}-{{browser}}.zip' },
  vite: () =>
    ({
      // Chrome extension pages can reject Vite's modulepreload hints (mkext); the popup is small.
      build: { modulePreload: false },
      plugins: [tailwindcss()],
    }) as WxtViteConfig,
});
