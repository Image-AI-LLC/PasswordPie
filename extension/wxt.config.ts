import { defineConfig } from 'wxt';
import { STORE_PACKAGE_ENV, extensionManifest } from './manifest';

const storePackage = process.env[STORE_PACKAGE_ENV] === '1';

// Entrypoints in src/app: a background and a content script. No extension pages, so no UI framework.
export default defineConfig({
  srcDir: 'src',
  entrypointsDir: 'app',
  manifestVersion: 3,
  manifest: ({ browser }) => extensionManifest({ browser, storePackage }),
  // Its own build folder, so the store package never replaces the unpacked `.output/chrome-mv3` (which keeps the key).
  outDirTemplate: storePackage ? '{{browser}}-mv{{manifestVersion}}-store' : undefined,
  // `-store` keeps the store package apart from a zip with the key.
  zip: { artifactTemplate: storePackage ? '{{name}}-{{version}}-{{browser}}-store.zip' : '{{name}}-{{version}}-{{browser}}.zip' },
});
