import js from '@eslint/js';
import globals from 'globals';

export default [
  { ignores: ['dist/**', 'node_modules/**', 'extension/src/boot/**'] },
  js.configs.recommended,
  {
    files: ['extension/src/**/*.js'],
    languageOptions: { ecmaVersion: 2023, sourceType: 'module', globals: { ...globals.browser, chrome: 'readonly' } },
  },
  {
    files: ['extension/src/guard.js', 'extension/src/bridge.js'],
    languageOptions: { sourceType: 'script' },
  },
  {
    files: ['tools/**/*.mjs', 'tests/**/*.js', 'eslint.config.js'],
    languageOptions: { ecmaVersion: 2023, sourceType: 'module', globals: { ...globals.node } },
  },
  { rules: { 'no-unused-vars': ['error', { argsIgnorePattern: '^_', caughtErrors: 'none' }] } },
];
