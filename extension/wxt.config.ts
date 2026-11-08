import { defineConfig } from 'wxt';
import { extensionManifest } from './manifest';

export default defineConfig({
  srcDir: 'src',
  manifestVersion: 3,
  manifest: extensionManifest,
  // `{{mode}}` keeps the store package apart from a production zip with the key.
  zip: { artifactTemplate: '{{name}}-{{version}}-{{browser}}-{{mode}}.zip' },
});
