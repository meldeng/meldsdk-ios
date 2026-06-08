const path = require('path');
const { getDefaultConfig, mergeConfig } = require('@react-native/metro-config');

// Local dev only: the wrapper is symlinked via `npm install <path>`, so let Metro watch its real
// folder, resolve it explicitly, and find its bare imports (react, @babel/runtime, …) in THIS
// app's node_modules. (An npm-installed wrapper wouldn't need any of this.)
const wrapper = path.resolve(__dirname, '..');

const config = {
  watchFolders: [wrapper],
  resolver: {
    unstable_enableSymlinks: true,
    nodeModulesPaths: [path.resolve(__dirname, 'node_modules')],
    extraNodeModules: {
      '@meldcrypto/react-native-sdk': wrapper,
    },
  },
};

module.exports = mergeConfig(getDefaultConfig(__dirname), config);
